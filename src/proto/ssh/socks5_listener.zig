//! SOCKS5 localhost listener. One IO thread owns every libssh2 operation on
//! the exclusive no-shell Session and all accepted client state machines.
//! Stable per-client buffers survive EAGAIN, with one pending channel open.
//! UI/control callers publish stop and read atomics; they never drive channels.
const std = @import("std");
const builtin = @import("builtin");
const socks = @import("socks5.zig");
const ssh_session = @import("session.zig");
const ssh_channel = @import("channel.zig");
const native = @import("generated_ssh_session");
const clock = @import("../../platform/realtime.zig");

pub const ListenerState = enum(u8) { off = 0, listening = 1, error_state = 2 };
/// 本地监听地址。默认只绑定回环地址；`any` 暴露到本机所有网卡。
pub const BindAddress = enum { loopback, any };
pub fn bindAddressName(address: BindAddress) []const u8 {
    return switch (address) {
        .loopback => "127.0.0.1",
        .any => "0.0.0.0",
    };
}
pub const Options = struct {
    /// true = 127.0.0.1，false = 0.0.0.0。
    bind127: bool = true,
    /// 绑定到 0.0.0.0 时必须由明确的红色风险确认设置为 true。
    exposure_confirmed: bool = false,
    /// 同时存在的代理连接上限。0 不允许任何连接。
    max_connections: u32 = 64,
    /// 0 由系统分配临时端口；非 0 在占用时按 SPEC 递增探测。
    requested_port: u16 = 1080,
};
pub const Stats = struct {
    connections_total: u64 = 0,
    connections_active: u32 = 0,
    bytes_up: u64 = 0,
    bytes_down: u64 = 0,
};

/// 只允许无认证（与设计稿 chips 的本地个人代理定位一致）。
const allowed_methods = [_]socks.Method{.no_auth};

/// accept 循环的 poll 周期：stop() 在无 shutdown 唤醒的平台上的最坏延迟。
/// 空闲时上行 poll 的等待（空闲隧道唤醒节奏）。
const idle_poll_ms: i32 = 15;
/// 下行出现数据后的自旋预算（0 超时 poll 的连续次数，压低下行延迟）。
/// 握手各分段的读守护：客户端 10s 内不完成握手即断。
const handshake_guard_ms: i32 = 10_000;
/// 隧道期单次 IO 守护：写对端 30s 无进展即拆（stop() join 的最坏等待）。
const io_guard_ms: i32 = 30_000;
/// 上下行搬运缓冲（每连接两块栈缓冲）。
const buf_size: usize = 16 * 1024;
/// 监听 backlog。
const listen_backlog: c_uint = 16;
/// 优雅关闭的排空上限（pollRead 1ms 粒度的迭代数）。
const drain_close_iters: u32 = 100;
/// 127.0.0.1（网络序由调用处转换）。
const loopback_ipv4: u32 = (127 << 24) | 1;

/// Zig 0.17 移除了 std.Thread.Mutex（std.atomic.Mutex 只有 tryLock 语义）；
/// 控制面临界极短，自旋锁实现阻塞语义（与 sftp_engine.zig 同源实现）。
const SpinMutex = struct {
    state: std.atomic.Value(bool) = .init(false), // false=unlocked, true=locked

    pub fn lock(self: *SpinMutex) void {
        while (self.state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(false, .release);
    }
};

/// IPv4 sockaddr（std.c 未透出 sockaddr_in，按平台布局自绘）。
const SockaddrIn = switch (builtin.os.tag) {
    // Linux：无 sin_len 前缀（0.17 的 Target.Os.Tag 已并入 .linux）。
    .linux => extern struct {
        family: u16 = std.c.AF.INET,
        port: u16 = 0, // 网络序
        addr: u32 = 0, // 网络序
        zero: [8]u8 = @splat(0),
    },
    // BSD/macOS：sin_len 前缀。
    else => extern struct {
        len: u8 = 16,
        family: u8 = 2, // AF_INET
        port: u16 = 0, // 网络序
        addr: u32 = 0, // 网络序
        zero: [8]u8 = @splat(0),
    },
};

const ListenSocket = struct { fd: std.posix.fd_t, port: u16 };

const ClientConn = struct {
    const Stage = enum { greeting, methods, request_header, domain_length, request_body, control, opening, stream, closing };
    const AfterControl = enum { request_header, stream, closing };
    fd: std.posix.fd_t,
    stage: Stage = .greeting,
    after_control: AfterControl = .closing,
    input: [262]u8 = undefined,
    have: usize = 0,
    need: usize = 2,
    control: [10]u8 = undefined,
    control_len: usize = 0,
    control_sent: usize = 0,
    host: ?[:0]u8 = null,
    port: u16 = 0,
    channel: ?ssh_channel.Channel = null,
    up: [buf_size]u8 = undefined,
    up_len: usize = 0,
    up_sent: usize = 0,
    write_pending: bool = false,
    down: [buf_size]u8 = undefined,
    down_len: usize = 0,
    down_sent: usize = 0,
    deadline: i128,
};

pub const Socks5Listener = struct {
    allocator: std.mem.Allocator,
    /// Exclusive no-shell lease while running; its owner must not call libssh2
    /// until stop has joined the IO thread. The Session outlives this listener.
    session: ?*ssh_session.Session = null,
    /// Shared mode has no Listener thread. Only the existing Worker/Relay IO
    /// owner drives ownerStep; controller callers use ForwardService commands.
    owner_driven: bool = false,
    owner_thread: ?std.Thread.Id = null,
    owner_paused: bool = false,
    owner_close_unknown: bool = false,

    // —— 控制面 ——
    lifecycle: SpinMutex = .{},
    stop_flag: std.atomic.Value(bool) = .init(false),
    active_admissions: std.atomic.Value(u32) = .init(0),
    max_connections: u32 = 64,
    bound_address: BindAddress = .loopback,
    listen_fd: std.posix.fd_t = -1, // 单一关闭者：stop()（accept 线程不关）
    accept_thread: ?std.Thread = null,
    clients: std.ArrayList(*ClientConn) = .empty,
    pending_open: ?*ClientConn = null,
    pending_close: ?*ClientConn = null,

    // —— 跨线程发布（UI chip 与统计） ——
    state_raw: std.atomic.Value(u8) = .init(@backingInt(ListenerState.off)),
    bound_port: std.atomic.Value(u16) = .init(0),
    stats_total: std.atomic.Value(u64) = .init(0),
    stats_active: std.atomic.Value(u32) = .init(0),
    stats_up: std.atomic.Value(u64) = .init(0),
    stats_down: std.atomic.Value(u64) = .init(0),

    /// 创建监听器。session 为 null 时监听器仍可运行（握手可完成，
    /// CONNECT 一律回 general_failure）——测试与“会话断开但 chip 未拆”降级共用。
    pub fn init(allocator: std.mem.Allocator, session: ?*ssh_session.Session) !*Socks5Listener {
        const self = try allocator.create(Socks5Listener);
        self.* = .{ .allocator = allocator, .session = session };
        return self;
    }
    pub fn initOwnerDriven(allocator: std.mem.Allocator, session: *ssh_session.Session) !*Socks5Listener {
        const self = try init(allocator, session);
        self.owner_driven = true;
        return self;
    }

    /// stop() 后释放自身。此后不得再调用任何方法。
    pub fn deinit(self: *Socks5Listener) void {
        if (self.owner_driven) {
            if (self.ownerStop() != .released) return;
            self.clients.deinit(self.allocator);
            self.allocator.destroy(self);
            return;
        }
        self.stop();
        if (self.cleanupReceipt() != .released) {
            std.log.err("SOCKS listener retains unresolved native cleanup", .{});
            return;
        }
        self.clients.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// spawn 监听线程并开始监听。已在监听时返回 error.AlreadyRunning。
    /// port 传 0 由系统分配临时端口（实际端口经 port() 读取，供 chip 展示）。
    pub fn start(self: *Socks5Listener, requested_port: u16) !void {
        return self.startWithOptions(.{ .requested_port = requested_port });
    }

    /// 按真实配置启动监听器。0.0.0.0 是显式暴露操作，必须携带确认标志。
    /// 非零端口冲突时自动向上探测到 SPEC 范围内的下一个可用端口。
    pub fn startWithOptions(self: *Socks5Listener, options: Options) !void {
        self.lifecycle.lock();
        defer self.lifecycle.unlock();
        if (self.accept_thread != null) return error.AlreadyRunning;
        if (self.clients.items.len != 0) return error.CleanupPending;
        if (self.session) |session| {
            if (session.state != .active or session.handle == null) return error.SessionNotActive;
            if (session.channel != null and !self.owner_driven) return error.ExclusiveSessionRequired;
        }
        if (!options.bind127 and !options.exposure_confirmed) return error.ExposureNotConfirmed;

        const address: BindAddress = if (options.bind127) .loopback else .any;
        const listen = openListenSocket(options.requested_port, address) catch |err| {
            self.state_raw.store(@backingInt(ListenerState.error_state), .release);
            return err;
        };
        self.listen_fd = listen.fd;
        self.bound_port.store(listen.port, .release);
        self.max_connections = options.max_connections;
        self.bound_address = address;
        self.active_admissions.store(0, .release);
        self.stop_flag.store(false, .release);

        self.state_raw.store(@backingInt(ListenerState.listening), .release);
        if (self.owner_driven) {
            self.owner_thread = std.Thread.getCurrentId();
            self.owner_paused = false;
            self.owner_close_unknown = false;
            if (self.session) |session| native.zw_libssh2_session_nonblocking(session.handle.?);
            return;
        }
        const thread = std.Thread.spawn(.{}, acceptRun, .{self}) catch |err| {
            closeFd(self.listen_fd);
            self.listen_fd = -1;
            self.bound_port.store(0, .release);
            self.active_admissions.store(0, .release);
            self.state_raw.store(@backingInt(ListenerState.error_state), .release);
            return err;
        };
        self.accept_thread = thread;
    }

    /// Publish stop and join the sole native IO owner after actual child cleanup.
    /// 幂等；可在 off 状态安全调用。
    pub fn stop(self: *Socks5Listener) void {
        if (self.owner_driven) {
            _ = self.ownerStop();
            return;
        }
        self.lifecycle.lock();
        defer self.lifecycle.unlock();
        self.stop_flag.store(true, .release);
        // 尽力唤醒 accept（macOS 的 shutdown 会打断 accept；其他平台由
        // IO loop 15ms poll 超时兜底）。
        if (self.listen_fd >= 0) _ = std.c.shutdown(self.listen_fd, std.c.SHUT.RDWR);
        if (self.accept_thread) |thread| {
            thread.join();
            self.accept_thread = null;
        }
        if (self.listen_fd >= 0) {
            closeFd(self.listen_fd);
            self.listen_fd = -1;
        }
        self.bound_port.store(0, .release);
        self.state_raw.store(@backingInt(if (self.clients.items.len == 0) ListenerState.off else ListenerState.error_state), .release);
    }

    pub fn state(self: *const Socks5Listener) ListenerState {
        return @fromBackingInt(@intCast(self.state_raw.load(.acquire)));
    }

    /// 实际监听端口（start(0) 后为系统分配值；off 状态为 0）。
    pub fn port(self: *const Socks5Listener) u16 {
        return self.bound_port.load(.acquire);
    }

    pub fn bindAddress(self: *const Socks5Listener) BindAddress {
        return self.bound_address;
    }

    pub fn bindAddressText(self: *const Socks5Listener) []const u8 {
        return bindAddressName(self.bound_address);
    }

    /// 原子读统计快照（UI chip：连接数/活跃/上下行字节）。
    pub fn stats(self: *const Socks5Listener) Stats {
        return .{
            .connections_total = self.stats_total.load(.monotonic),
            .connections_active = self.stats_active.load(.monotonic),
            .bytes_up = self.stats_up.load(.monotonic),
            .bytes_down = self.stats_down.load(.monotonic),
        };
    }

    /// After stop has joined the sole IO owner, unresolved whole-session
    /// cleanup may be retried by its original owner. Never free live handles.
    pub fn cleanupReceipt(self: *Socks5Listener) ssh_session.ReleaseReceipt {
        if (self.owner_driven) return self.ownerReceipt();
        if (self.accept_thread != null) return .awaiting;
        if (self.clients.items.len == 0) return .released;
        const session = self.session orelse return .unknown;
        const receipt = session.closeReceipt();
        if (receipt == .released) self.releaseAfterTransport();
        return receipt;
    }

    fn ownerCheck(self: *Socks5Listener) !void {
        if (!self.owner_driven or self.accept_thread != null) return error.NotOwnerDriven;
        const current = std.Thread.getCurrentId();
        if (self.owner_thread) |owner| {
            if (owner != current) return error.WrongIoOwner;
        } else self.owner_thread = current;
    }
    /// One bounded nonblocking tick, called by the existing native IO owner.
    pub fn ownerStep(self: *Socks5Listener) !void {
        try self.ownerCheck();
        if (self.stop_flag.load(.acquire)) {
            _ = self.ownerStop();
            return;
        }
        _ = self.acceptOne();
        for (self.clients.items) |conn| _ = self.stepClient(conn);
        self.reapClosed();
    }
    /// Pause keeps the local listener/port. Only the original native owner
    /// drains children; it never closes the parent PTY Session to do so.
    pub fn ownerPause(self: *Socks5Listener) !void {
        try self.ownerCheck();
        self.owner_paused = true;
        for (self.clients.items) |conn| self.beginClose(conn);
        for (self.clients.items) |conn| _ = self.stepClose(conn);
        self.reapClosed();
    }
    /// The caller has obtained the real parent Session release receipt. No
    /// native child pointer is inspected after that receipt invalidated it.
    pub fn ownerSessionReleased(self: *Socks5Listener) !void {
        try self.ownerCheck();
        self.releaseAfterTransport();
        self.session = null;
        self.owner_paused = true;
        self.owner_close_unknown = false;
        self.owner_thread = null;
    }
    pub fn ownerResume(self: *Socks5Listener, session: *ssh_session.Session) !void {
        try self.ownerCheck();
        if (self.session != null or self.pending_open != null or self.pending_close != null) return error.PreviousTransportNotReleased;
        if (session.state != .active or session.handle == null) return error.SessionNotActive;
        self.session = session;
        self.owner_paused = false;
        self.owner_close_unknown = false;
        native.zw_libssh2_session_nonblocking(session.handle.?);
    }
    pub fn ownerStop(self: *Socks5Listener) ssh_session.ReleaseReceipt {
        self.ownerCheck() catch return .unknown;
        self.stop_flag.store(true, .release);
        if (self.listen_fd >= 0) {
            closeFd(self.listen_fd);
            self.listen_fd = -1;
        }
        self.bound_port.store(0, .release);
        for (self.clients.items) |conn| self.beginClose(conn);
        for (self.clients.items) |conn| _ = self.stepClose(conn);
        self.reapClosed();
        const receipt = self.ownerReceipt();
        self.state_raw.store(@backingInt(if (receipt == .released) ListenerState.off else ListenerState.error_state), .release);
        return receipt;
    }
    fn ownerReceipt(self: *Socks5Listener) ssh_session.ReleaseReceipt {
        if (self.clients.items.len == 0) return .released;
        return if (self.owner_close_unknown) .unknown else .awaiting;
    }

    fn acceptRun(self: *Socks5Listener) void {
        if (self.session) |session| {
            const handle = session.handle orelse {
                self.state_raw.store(@backingInt(ListenerState.error_state), .release);
                return;
            };
            native.zw_libssh2_session_nonblocking(handle);
        }
        var polls: std.ArrayList(std.posix.pollfd) = .empty;
        defer polls.deinit(self.allocator);
        while (!self.stop_flag.load(.acquire)) {
            var progressed = self.acceptOne();
            for (self.clients.items) |conn| progressed = self.stepClient(conn) or progressed;
            self.reapClosed();
            if (progressed) continue;
            polls.clearRetainingCapacity();
            polls.append(self.allocator, .{ .fd = self.listen_fd, .events = std.posix.POLL.IN, .revents = 0 }) catch break;
            if (self.session) |session| if (session.state == .active) {
                polls.append(self.allocator, .{ .fd = session.socket_fd, .events = std.posix.POLL.IN, .revents = 0 }) catch break;
            };
            for (self.clients.items) |conn| {
                if (conn.fd < 0) continue;
                const events: i16 = switch (conn.stage) {
                    .greeting, .methods, .request_header, .domain_length, .request_body => std.posix.POLL.IN,
                    .control => std.posix.POLL.OUT,
                    .stream => (if (conn.up_sent == conn.up_len) @as(i16, std.posix.POLL.IN) else 0) | (if (conn.down_sent < conn.down_len) @as(i16, std.posix.POLL.OUT) else 0),
                    .opening, .closing => 0,
                };
                if (events != 0) polls.append(self.allocator, .{ .fd = conn.fd, .events = events, .revents = 0 }) catch break;
            }
            _ = std.posix.poll(polls.items, idle_poll_ms) catch break;
        }
        if (!self.stop_flag.load(.acquire)) self.state_raw.store(@backingInt(ListenerState.error_state), .release);
        // All accepted sockets and native children still belong to this owner.
        for (self.clients.items) |conn| self.beginClose(conn);
        const deadline = clock.monotonicNs() + 250 * std.time.ns_per_ms;
        while (self.clients.items.len != 0 and clock.monotonicNs() < deadline) {
            for (self.clients.items) |conn| _ = self.stepClose(conn);
            self.reapClosed();
            if (self.clients.items.len != 0) sleepMs(1);
        }
        if (self.clients.items.len != 0) {
            // This listener's Session is exclusive, with no PTY/other IO owner.
            // A stuck EAGAIN context cannot be abandoned while freeing buffers.
            if (self.session) |session| {
                if (session.closeReceipt() == .released) self.releaseAfterTransport();
            }
        }
    }

    fn acceptOne(self: *Socks5Listener) bool {
        if (!(pollFd(self.listen_fd, std.posix.POLL.IN, 0) catch false)) return false;
        const fd = std.c.accept(self.listen_fd, null, null);
        if (fd < 0) return false;
        if (self.clients.items.len >= self.max_connections or native.zw_ssh_socket_set_nonblocking(fd) != 0) {
            closeFd(fd);
            return true;
        }
        if (builtin.os.tag == .macos) {
            const enabled: c_int = 1;
            _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, @ptrCast(&enabled), @sizeOf(c_int));
        }
        const conn = self.allocator.create(ClientConn) catch {
            closeFd(fd);
            return true;
        };
        conn.* = .{ .fd = fd, .deadline = clock.monotonicNs() + @as(i128, handshake_guard_ms) * std.time.ns_per_ms };
        self.clients.append(self.allocator, conn) catch {
            self.allocator.destroy(conn);
            closeFd(fd);
            return true;
        };
        _ = self.stats_total.fetchAdd(1, .monotonic);
        _ = self.stats_active.fetchAdd(1, .monotonic);
        _ = self.active_admissions.fetchAdd(1, .monotonic);
        return true;
    }

    fn stepClient(self: *Socks5Listener, conn: *ClientConn) bool {
        if (conn.stage != .stream and conn.stage != .closing and clock.monotonicNs() >= conn.deadline) self.beginClose(conn);
        return switch (conn.stage) {
            .greeting, .methods, .request_header, .domain_length, .request_body => self.stepHandshake(conn),
            .control => self.stepControl(conn),
            .opening => self.stepOpen(conn),
            .stream => self.stepStream(conn),
            .closing => self.stepClose(conn),
        };
    }

    fn stepHandshake(self: *Socks5Listener, conn: *ClientConn) bool {
        const rc = std.c.read(conn.fd, conn.input[conn.have..].ptr, conn.need - conn.have);
        if (rc < 0) {
            if (std.c.errno(rc) == .AGAIN or std.c.errno(rc) == .INTR) return false;
            self.beginClose(conn);
            return true;
        }
        if (rc == 0) {
            self.beginClose(conn);
            return true;
        }
        conn.have += @intCast(rc);
        if (conn.have < conn.need) return true;
        switch (conn.stage) {
            .greeting => {
                if (conn.input[0] != socks.version) {
                    self.control(conn, &.{ 5, 1 }, .closing);
                } else if (conn.input[1] == 0) {
                    self.control(conn, &.{ 5, 0xff }, .closing);
                } else {
                    conn.need = 2 + @as(usize, conn.input[1]);
                    conn.stage = .methods;
                }
            },
            .methods => {
                const method = socks.Codec.selectMethod(conn.input[0..conn.need], &allowed_methods) catch socks.Method.no_acceptable;
                self.control(conn, &.{ 5, @backingInt(method) }, if (method == .no_auth) .request_header else .closing);
            },
            .request_header => {
                if (conn.input[0] != 5 or conn.input[2] != 0) {
                    self.queueReply(conn, .general_failure, .closing);
                } else if (conn.input[1] != 1) {
                    self.queueReply(conn, .command_not_supported, .closing);
                } else switch (conn.input[3]) {
                    1 => {
                        conn.need = 10;
                        conn.stage = .request_body;
                    },
                    3 => {
                        conn.need = 5;
                        conn.stage = .domain_length;
                    },
                    4 => {
                        conn.need = 22;
                        conn.stage = .request_body;
                    },
                    else => self.queueReply(conn, .address_type_not_supported, .closing),
                }
            },
            .domain_length => {
                if (conn.input[4] == 0) self.queueReply(conn, .general_failure, .closing) else {
                    conn.need = 7 + @as(usize, conn.input[4]);
                    conn.stage = .request_body;
                }
            },
            .request_body => {
                const request = decodeConnectRequestFrame(conn.input[0..conn.need]) catch {
                    self.queueReply(conn, .general_failure, .closing);
                    return true;
                };
                if (self.session == null) {
                    self.queueReply(conn, if (self.owner_driven and self.owner_paused) .network_unreachable else .general_failure, .closing);
                    return true;
                }
                conn.host = socks.addressHost(self.allocator, request.address) catch |err| {
                    self.queueReply(conn, if (err == error.UnsupportedAddressType) .address_type_not_supported else .general_failure, .closing);
                    return true;
                };
                conn.port = request.port;
                conn.stage = .opening;
            },
            else => unreachable,
        }
        return true;
    }

    fn control(_: *Socks5Listener, conn: *ClientConn, bytes: []const u8, next: ClientConn.AfterControl) void {
        @memcpy(conn.control[0..bytes.len], bytes);
        conn.control_len = bytes.len;
        conn.control_sent = 0;
        conn.after_control = next;
        conn.stage = .control;
    }
    fn queueReply(self: *Socks5Listener, conn: *ClientConn, value: socks.Reply, next: ClientConn.AfterControl) void {
        var bytes: [10]u8 = undefined;
        self.control(conn, replyFrame(value, &bytes) catch unreachable, next);
    }
    fn stepControl(self: *Socks5Listener, conn: *ClientConn) bool {
        const rc = std.c.write(conn.fd, conn.control[conn.control_sent..].ptr, conn.control_len - conn.control_sent);
        if (rc < 0) {
            if (std.c.errno(rc) == .AGAIN or std.c.errno(rc) == .INTR) return false;
            self.beginClose(conn);
            return true;
        }
        if (rc == 0) return false;
        conn.control_sent += @intCast(rc);
        if (conn.control_sent == conn.control_len) switch (conn.after_control) {
            .request_header => {
                conn.stage = .request_header;
                conn.have = 0;
                conn.need = 4;
            },
            .stream => {
                conn.stage = .stream;
                conn.deadline = clock.monotonicNs() + @as(i128, io_guard_ms) * std.time.ns_per_ms;
            },
            .closing => self.beginClose(conn),
        };
        return true;
    }
    fn stepOpen(self: *Socks5Listener, conn: *ClientConn) bool {
        if (self.pending_open != null and self.pending_open != conn) return false;
        if (self.pending_close != null) return false;
        if (self.owner_paused and self.pending_open != conn) {
            self.queueReply(conn, .network_unreachable, .closing);
            return true;
        }
        const session = self.session orelse {
            self.beginClose(conn);
            return true;
        };
        self.pending_open = conn;
        const channel = session.openDirectTcpip(conn.host.?, conn.port) catch |err| {
            if (err == error.ChannelOpenBusy) return false;
            if (err == error.OpenDirectTcpipFailed and native.zw_libssh2_session_last_error(session.handle.?) == -37) return false;
            self.pending_open = null;
            if (conn.stage == .closing) return true;
            self.queueReply(conn, tunnelErrorReply(err), .closing);
            return true;
        };
        self.pending_open = null;
        conn.channel = channel;
        if (conn.stage != .closing) self.queueReply(conn, .succeeded, .stream);
        return true;
    }
    fn stepWrite(self: *Socks5Listener, conn: *ClientConn) bool {
        if (conn.up_sent == conn.up_len) return false;
        const channel = if (conn.channel) |*value| value else return false;
        conn.write_pending = true;
        const count = channel.writer().write(conn.up[conn.up_sent..conn.up_len]) catch {
            conn.write_pending = false;
            self.beginClose(conn);
            return true;
        };
        if (count == 0) return false;
        conn.write_pending = false;
        conn.up_sent += count;
        _ = self.stats_up.fetchAdd(count, .monotonic);
        conn.deadline = clock.monotonicNs() + @as(i128, io_guard_ms) * std.time.ns_per_ms;
        return true;
    }
    fn stepStream(self: *Socks5Listener, conn: *ClientConn) bool {
        var progressed = false;
        if (conn.up_sent == conn.up_len) {
            const rc = std.c.read(conn.fd, &conn.up, conn.up.len);
            if (rc == 0) {
                self.beginClose(conn);
                return true;
            }
            if (rc > 0) {
                conn.up_len = @intCast(rc);
                conn.up_sent = 0;
                progressed = true;
            }
            if (rc < 0 and std.c.errno(rc) != .AGAIN and std.c.errno(rc) != .INTR) {
                self.beginClose(conn);
                return true;
            }
        }
        progressed = self.stepWrite(conn) or progressed;
        if (conn.stage == .closing) return true;
        if (conn.down_sent == conn.down_len) {
            const channel = if (conn.channel) |*value| value else return false;
            switch (channel.reader().read(&conn.down) catch {
                self.beginClose(conn);
                return true;
            }) {
                .eof => {
                    self.beginClose(conn);
                    return true;
                },
                .would_block => {},
                .bytes => |count| {
                    conn.down_len = count;
                    conn.down_sent = 0;
                    progressed = true;
                },
            }
        }
        if (conn.down_sent < conn.down_len) {
            const rc = std.c.write(conn.fd, conn.down[conn.down_sent..].ptr, conn.down_len - conn.down_sent);
            if (rc > 0) {
                conn.down_sent += @intCast(rc);
                _ = self.stats_down.fetchAdd(@intCast(rc), .monotonic);
                conn.deadline = clock.monotonicNs() + @as(i128, io_guard_ms) * std.time.ns_per_ms;
                progressed = true;
            } else if (rc < 0 and std.c.errno(rc) != .AGAIN and std.c.errno(rc) != .INTR) {
                self.beginClose(conn);
                return true;
            }
        }
        if (!progressed and (conn.up_sent < conn.up_len or conn.down_sent < conn.down_len) and clock.monotonicNs() > conn.deadline) self.beginClose(conn);
        return progressed;
    }
    fn beginClose(_: *Socks5Listener, conn: *ClientConn) void {
        if (conn.stage != .closing) conn.deadline = clock.monotonicNs() + 2 * std.time.ns_per_s;
        conn.stage = .closing;
        if (conn.fd >= 0) {
            // Drain only bytes already buffered locally, never wait for a peer.
            _ = std.c.shutdown(conn.fd, std.c.SHUT.WR);
            var discard: [1024]u8 = undefined;
            for (0..16) |_| {
                const rc = std.c.read(conn.fd, &discard, discard.len);
                if (rc <= 0) break;
            }
            closeFd(conn.fd);
            conn.fd = -1;
        }
    }
    fn stepClose(self: *Socks5Listener, conn: *ClientConn) bool {
        if (clock.monotonicNs() >= conn.deadline) {
            if (self.owner_driven) {
                self.owner_close_unknown = true;
            } else {
                self.state_raw.store(@backingInt(ListenerState.error_state), .release);
                self.stop_flag.store(true, .release);
                return false;
            }
        }
        if (self.pending_open == conn) return self.stepOpen(conn);
        if (conn.write_pending) return self.stepWrite(conn);
        if (conn.channel) |*channel| {
            if (self.pending_close != null and self.pending_close != conn) return false;
            self.pending_close = conn;
            const session = self.session orelse return false;
            if (session.closeChannelReceipt(channel) != .released) return false;
            self.pending_close = null;
            conn.channel = null;
            return true;
        }
        return false;
    }
    fn reapClosed(self: *Socks5Listener) void {
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const conn = self.clients.items[i];
            if (conn.stage != .closing or conn.channel != null or self.pending_open == conn or conn.write_pending) {
                i += 1;
                continue;
            }
            if (conn.host) |host| self.allocator.free(host);
            self.allocator.destroy(conn);
            _ = self.clients.swapRemove(i);
            _ = self.stats_active.fetchSub(1, .monotonic);
            _ = self.active_admissions.fetchSub(1, .monotonic);
        }
    }
    fn releaseAfterTransport(self: *Socks5Listener) void {
        self.pending_open = null;
        self.pending_close = null;
        for (self.clients.items) |conn| {
            conn.write_pending = false;
            conn.channel = null;
            self.beginClose(conn);
        }
        self.reapClosed();
    }

    // -----------------------------------------------------------------
    // 纯编解码（供网络路径与测试共用）
    // -----------------------------------------------------------------

    /// 解析完整 CONNECT 请求帧（ver cmd rsv atyp addr port）。
    /// 与 socks5_server.decodeRequest 的差异：命令字节走安全 switch（未知命令
    /// 返回错误而非 @fromBackingInt 的未定义枚举 panic）。
    fn decodeConnectRequestFrame(bytes: []const u8) !socks.ConnectRequest {
        if (bytes.len < 7 or bytes[0] != socks.version or bytes[2] != 0) return error.InvalidRequest;
        const command: socks.Command = switch (bytes[1]) {
            1 => .connect,
            2 => .bind,
            3 => .udp_associate,
            else => return error.UnsupportedCommand,
        };
        var cursor: usize = 4;
        const address: socks.Address = switch (bytes[3]) {
            1 => blk: {
                if (bytes.len < cursor + 4 + 2) return error.TruncatedRequest;
                var value: [4]u8 = undefined;
                @memcpy(&value, bytes[cursor..][0..4]);
                cursor += 4;
                break :blk .{ .ipv4 = value };
            },
            3 => blk: {
                if (bytes.len < cursor + 1) return error.TruncatedRequest;
                const len = bytes[cursor];
                cursor += 1;
                if (bytes.len < cursor + len + 2) return error.TruncatedRequest;
                const value = bytes[cursor .. cursor + len];
                cursor += len;
                break :blk .{ .domain = value };
            },
            4 => blk: {
                if (bytes.len < cursor + 16 + 2) return error.TruncatedRequest;
                var value: [16]u8 = undefined;
                @memcpy(&value, bytes[cursor..][0..16]);
                cursor += 16;
                break :blk .{ .ipv6 = value };
            },
            else => return error.UnsupportedAddressType,
        };
        const target_port = std.mem.readInt(u16, bytes[cursor..][0..2], .big);
        return .{ .command = command, .address = address, .port = target_port };
    }

    /// 回复帧构造：固定 10 字节 IPv4 零绑定（BND.ADDR 0.0.0.0:0，RFC 允许）。
    fn replyFrame(reply: socks.Reply, out: []u8) ![]u8 {
        return socks.Codec.encodeConnectResponse(.{
            .reply = reply,
            .address = .{ .ipv4 = .{ 0, 0, 0, 0 } },
            .port = 0,
        }, out);
    }
};

// ---------------------------------------------------------------------------
// 网络小工具（libc socket 直写；0.17 std.net 已迁 std.Io.net，需 Io 实例）
// ---------------------------------------------------------------------------

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

/// 优雅关闭：先 shutdown(WR) 再短排空对端剩余数据，避免「带未读数据关闭」
/// 触发 RST 打断对端正在读取的回复帧；排空上限 100ms，随后强制关闭。
fn gracefulClose(fd: std.posix.fd_t) void {
    _ = std.c.shutdown(fd, std.c.SHUT.WR);
    var junk: [256]u8 = undefined;
    var iters: u32 = 0;
    while (iters < drain_close_iters) : (iters += 1) {
        const n = pollRead(fd, &junk, 1) catch break; // TimedOut / PollFailed / Reset
        if (n == 0) break; // 对端已关
    }
    closeFd(fd);
}

/// 毫秒级睡眠（0.17 移除了 std.Thread.sleep；不经 std.Io 直走 libc）。
fn sleepMs(ms: u64) void {
    const ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

/// 建立监听 socket。默认回环；暴露模式绑定 0.0.0.0。非零端口冲突时
/// 按设计向上探测，绝不从 65535 回绕到 0。
fn openListenSocket(requested_port: u16, address: BindAddress) !ListenSocket {
    var candidate = requested_port;
    while (true) {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        const one: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, @ptrCast(&one), @sizeOf(c_int));
        const bind_addr: u32 = if (address == .loopback) loopback_ipv4 else 0;
        var addr: SockaddrIn = .{
            .port = std.mem.nativeToBig(u16, candidate),
            .addr = std.mem.nativeToBig(u32, bind_addr),
        };
        const bind_rc = std.c.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrIn));
        if (bind_rc != 0) {
            const errno = std.c.errno(bind_rc);
            closeFd(fd);
            if (errno == .ADDRINUSE and candidate != 0 and candidate < std.math.maxInt(u16)) {
                candidate += 1;
                continue;
            }
            return switch (errno) {
                .ADDRINUSE => error.AddressInUse,
                .ACCES => error.AccessDenied,
                else => error.BindFailed,
            };
        }
        if (std.c.listen(fd, listen_backlog) != 0) {
            closeFd(fd);
            return error.ListenFailed;
        }
        var bound: SockaddrIn = undefined;
        var bound_len: std.c.socklen_t = @sizeOf(SockaddrIn);
        var port = candidate;
        if (std.c.getsockname(fd, @ptrCast(&bound), &bound_len) == 0) {
            port = std.mem.bigToNative(u16, bound.port);
        }
        return .{ .fd = fd, .port = port };
    }
}

/// poll 等待单 fd 事件。true=就绪，false=超时。
fn pollFd(fd: std.posix.fd_t, events: i16, timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return error.PollFailed;
    return ready > 0;
}

/// poll 守护的读：超时回 error.TimedOut，EOF 回 0，伪唤醒（WouldBlock）重试。
fn pollRead(fd: std.posix.fd_t, buf: []u8, timeout_ms: i32) !usize {
    while (true) {
        if (!try pollFd(fd, std.posix.POLL.IN, timeout_ms)) return error.TimedOut;
        const n = std.posix.read(fd, buf) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        return n;
    }
}

/// poll 守护的写全量（nonblocking 语义由 blocking fd + poll 守护近似：
/// POLLOUT 就绪后 write 至少推进一部分，不会无限阻塞）。
fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (!try pollFd(fd, std.posix.POLL.OUT, io_guard_ms)) return error.TimedOut;
        const rc = std.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0) {
            switch (std.c.errno(rc)) {
                .AGAIN, .INTR => continue,
                .PIPE => return error.BrokenPipe,
                else => return error.WriteFailed,
            }
        }
        const n: usize = @intCast(rc);
        if (n == 0) return error.BrokenPipe;
        offset += n;
    }
}

fn readExact(fd: std.posix.fd_t, buf: []u8, timeout_ms: i32) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try pollRead(fd, buf[got..], timeout_ms);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

fn sendMethodReply(fd: std.posix.fd_t, method: socks.Method) !void {
    const frame = [_]u8{ socks.version, @backingInt(method) };
    try writeAllFd(fd, &frame);
}

/// ver != 5：回 0x05 0x01 后断开（任务约定；0x01 取 general_failure 码）。
fn sendBadVersionReply(fd: std.posix.fd_t) void {
    writeAllFd(fd, &[_]u8{ socks.version, @backingInt(socks.Reply.general_failure) }) catch {};
}

fn sendReplyFrame(fd: std.posix.fd_t, reply: socks.Reply) !void {
    var buf: [10]u8 = undefined;
    try writeAllFd(fd, try Socks5Listener.replyFrame(reply, &buf));
}

/// openDirectTcpip 失败 → Reply 粗分（shim 未透出 libssh2 errno，
/// 统一按最常见情况归并；后续 c.zig 透出 errno 后细化）。
fn tunnelErrorReply(err: anyerror) socks.Reply {
    return switch (err) {
        error.OpenDirectTcpipFailed => .connection_refused,
        else => .general_failure,
    };
}

// ---------------------------------------------------------------------------
// 测试（无真实 SSH：session 传 null，CONNECT 一律 general_failure；
// 走真实 127.0.0.1 回环 socket 验证握手/回复/状态机/统计）
// ---------------------------------------------------------------------------

fn connectLocal(port: u16) !std.posix.fd_t {
    const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketCreateFailed;
    errdefer closeFd(fd);
    var addr: SockaddrIn = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, loopback_ipv4),
    };
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrIn)) != 0) return error.ConnectFailed;
    return fd;
}

fn waitForIdle(listener: *Socks5Listener) !void {
    var waited_ms: u32 = 0;
    while (listener.stats().connections_active != 0) {
        if (waited_ms >= 5000) return error.TestTimedOut;
        sleepMs(5);
        waited_ms += 5;
    }
}

fn expectClosedByPeer(fd: std.posix.fd_t) !void {
    var junk: [16]u8 = undefined;
    // 服务端带未读数据关闭时可能以 RST 代替 FIN，两者都算「已断开」。
    if (readExact(fd, &junk, handshake_guard_ms)) |_| {
        return error.TestUnexpectedResult; // 对端未关
    } else |err| switch (err) {
        error.EndOfStream, error.ConnectionResetByPeer => {},
        else => return err,
    }
}

test "connect request frame decodes domain and ipv4 targets" {
    var buf: [64]u8 = undefined;

    const domain_frame = try socks.Codec.encodeConnectRequest(
        .{ .command = .connect, .address = .{ .domain = "db.internal" }, .port = 5432 },
        &buf,
    );
    const domain = try Socks5Listener.decodeConnectRequestFrame(domain_frame);
    try std.testing.expectEqual(socks.Command.connect, domain.command);
    try std.testing.expectEqualStrings("db.internal", domain.address.domain);
    try std.testing.expectEqual(@as(u16, 5432), domain.port);

    const ipv4_frame = try socks.Codec.encodeConnectRequest(
        .{ .command = .connect, .address = .{ .ipv4 = .{ 10, 0, 0, 1 } }, .port = 22 },
        &buf,
    );
    const ipv4 = try Socks5Listener.decodeConnectRequestFrame(ipv4_frame);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 1 }, &ipv4.address.ipv4);
    try std.testing.expectEqual(@as(u16, 22), ipv4.port);

    // 未知命令字节安全报错（不触发枚举 panic）。
    var bad = ipv4_frame;
    bad[1] = 99;
    try std.testing.expectError(error.UnsupportedCommand, Socks5Listener.decodeConnectRequestFrame(bad));

    // 截断帧报错（独立缓冲，避免与上面的命令字节改写共用内存）。
    var trunc_buf: [64]u8 = undefined;
    const trunc_frame = try socks.Codec.encodeConnectRequest(
        .{ .command = .connect, .address = .{ .ipv4 = .{ 10, 0, 0, 1 } }, .port = 22 },
        &trunc_buf,
    );
    try std.testing.expectError(error.TruncatedRequest, Socks5Listener.decodeConnectRequestFrame(trunc_frame[0..8]));
}

test "reply frames are ten-byte zero-bind ipv4" {
    var buf: [10]u8 = undefined;
    const success = try Socks5Listener.replyFrame(.succeeded, &buf);
    try std.testing.expectEqual(@as(usize, 10), success.len);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0, 0, 1, 0, 0, 0, 0, 0, 0 }, success);

    const unsupported = try Socks5Listener.replyFrame(.command_not_supported, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 5, 7, 0, 1, 0, 0, 0, 0, 0, 0 }, unsupported);

    const refused = try Socks5Listener.replyFrame(.connection_refused, &buf);
    try std.testing.expectEqual(@as(u8, 5), refused[1]); // reply code = connection_refused
}

test "stats snapshot reflects atomic counters without listener" {
    const listener = try Socks5Listener.init(std.testing.allocator, null);
    defer listener.deinit();

    _ = listener.stats_total.fetchAdd(3, .monotonic);
    _ = listener.stats_active.fetchAdd(2, .monotonic);
    _ = listener.stats_up.fetchAdd(100, .monotonic);
    _ = listener.stats_down.fetchAdd(50, .monotonic);

    const snapshot = listener.stats();
    try std.testing.expectEqual(@as(u64, 3), snapshot.connections_total);
    try std.testing.expectEqual(@as(u32, 2), snapshot.connections_active);
    try std.testing.expectEqual(@as(u64, 100), snapshot.bytes_up);
    try std.testing.expectEqual(@as(u64, 50), snapshot.bytes_down);

    // 未启动：off 且端口 0；deinit（内部 stop）幂等。
    try std.testing.expectEqual(ListenerState.off, listener.state());
    try std.testing.expectEqual(@as(u16, 0), listener.port());
}

test "listener state machine start stop and restart" {
    const listener = try Socks5Listener.init(std.testing.allocator, null);
    defer listener.deinit();

    try std.testing.expectEqual(ListenerState.off, listener.state());
    try listener.start(0);
    try std.testing.expectEqual(ListenerState.listening, listener.state());
    const first_port = listener.port();
    try std.testing.expect(first_port != 0); // 系统分配临时端口

    try std.testing.expectError(error.AlreadyRunning, listener.start(8080));

    // 端口确实可连（真监听）：完整握手一轮，保证 accept/服务线程确定性收敛。
    {
        const probe = try connectLocal(first_port);
        defer gracefulClose(probe);
        try writeAllFd(probe, &[_]u8{ 5, 1, 0 });
        var method_reply: [2]u8 = undefined;
        try readExact(probe, &method_reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 0 }, &method_reply);
    }
    try waitForIdle(listener); // probe 连接收尾（无会话 → general_failure）
    try std.testing.expectEqual(@as(u64, 1), listener.stats().connections_total);

    listener.stop();
    try std.testing.expectEqual(ListenerState.off, listener.state());
    try std.testing.expectEqual(@as(u16, 0), listener.port());
    listener.stop(); // 幂等

    // 重启：新随机端口，状态回到 listening。
    try listener.start(0);
    try std.testing.expectEqual(ListenerState.listening, listener.state());
    try std.testing.expect(listener.port() != 0);
    listener.stop();
    try std.testing.expectEqual(ListenerState.off, listener.state());
}

test "listener options require exposure confirmation and expose selected address" {
    const listener = try Socks5Listener.init(std.testing.allocator, null);
    defer listener.deinit();

    try std.testing.expectError(error.ExposureNotConfirmed, listener.startWithOptions(.{
        .bind127 = false,
        .exposure_confirmed = false,
        .requested_port = 0,
    }));
    try std.testing.expectEqual(ListenerState.off, listener.state());

    // Port 0 keeps this test isolated from production ports and never exposes
    // a fixed external endpoint. The socket is still bound to all interfaces,
    // which is verified through the published address API.
    try listener.startWithOptions(.{
        .bind127 = false,
        .exposure_confirmed = true,
        .requested_port = 0,
        .max_connections = 2,
    });
    try std.testing.expectEqual(BindAddress.any, listener.bindAddress());
    try std.testing.expectEqualStrings("0.0.0.0", listener.bindAddressText());
    try std.testing.expect(listener.port() != 0);
    listener.stop();
}

test "listener serves no-auth handshake and fails closed without session" {
    const listener = try Socks5Listener.init(std.testing.allocator, null);
    defer listener.deinit();
    try listener.start(0);
    const port = listener.port();

    // 连接 1：domain 目标 → 无会话 → general_failure（10 字节帧）。
    {
        const fd = try connectLocal(port);
        defer closeFd(fd);
        try writeAllFd(fd, &[_]u8{ 5, 1, 0 });
        var method_reply: [2]u8 = undefined;
        try readExact(fd, &method_reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 0 }, &method_reply);

        var request_buf: [64]u8 = undefined;
        const request = try socks.Codec.encodeConnectRequest(
            .{ .command = .connect, .address = .{ .domain = "refused.invalid" }, .port = 9 },
            &request_buf,
        );
        try writeAllFd(fd, request);
        var reply: [10]u8 = undefined;
        try readExact(fd, &reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 1, 0, 1, 0, 0, 0, 0, 0, 0 }, &reply);
    }

    // 连接 2：ipv4 目标 → 同样 general_failure。
    {
        const fd = try connectLocal(port);
        defer closeFd(fd);
        try writeAllFd(fd, &[_]u8{ 5, 1, 0 });
        var method_reply: [2]u8 = undefined;
        try readExact(fd, &method_reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 0 }, &method_reply);

        var request_buf: [64]u8 = undefined;
        const request = try socks.Codec.encodeConnectRequest(
            .{ .command = .connect, .address = .{ .ipv4 = .{ 10, 0, 0, 1 } }, .port = 22 },
            &request_buf,
        );
        try writeAllFd(fd, request);
        var reply: [10]u8 = undefined;
        try readExact(fd, &reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 1, 0, 1, 0, 0, 0, 0, 0, 0 }, &reply);
    }

    try waitForIdle(listener);
    const snapshot = listener.stats();
    try std.testing.expectEqual(@as(u64, 2), snapshot.connections_total);
    try std.testing.expectEqual(@as(u32, 0), snapshot.connections_active);
    // 无隧道：字节计数保持 0；隧道字节数只在 pump 路径累加。
    try std.testing.expectEqual(@as(u64, 0), snapshot.bytes_up);
    try std.testing.expectEqual(@as(u64, 0), snapshot.bytes_down);

    listener.stop();
    try std.testing.expectEqual(ListenerState.off, listener.state());
}

test "listener rejects bad version method and command with correct frames" {
    const listener = try Socks5Listener.init(std.testing.allocator, null);
    defer listener.deinit();
    try listener.start(0);
    const port = listener.port();

    // ver != 5：回 0x05 0x01 后断开。
    {
        const fd = try connectLocal(port);
        defer closeFd(fd);
        try writeAllFd(fd, &[_]u8{ 4, 1, 0 });
        var reply: [2]u8 = undefined;
        try readExact(fd, &reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 1 }, &reply);
        try expectClosedByPeer(fd);
    }

    // 无可接受方法（只提供 user_pass）：回 0x05 0xff 后断开。
    {
        const fd = try connectLocal(port);
        defer closeFd(fd);
        try writeAllFd(fd, &[_]u8{ 5, 1, 2 });
        var reply: [2]u8 = undefined;
        try readExact(fd, &reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 0xff }, &reply);
        try expectClosedByPeer(fd);
    }

    // BIND 命令：回 command_not_supported（0x05 0x07 …）。
    {
        const fd = try connectLocal(port);
        defer closeFd(fd);
        try writeAllFd(fd, &[_]u8{ 5, 1, 0 });
        var method_reply: [2]u8 = undefined;
        try readExact(fd, &method_reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 0 }, &method_reply);

        try writeAllFd(fd, &[_]u8{ 5, 2, 0, 1, 10, 0, 0, 1, 0, 80 });
        var reply: [10]u8 = undefined;
        try readExact(fd, &reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 7, 0, 1, 0, 0, 0, 0, 0, 0 }, &reply);
        try expectClosedByPeer(fd);
    }

    // 不支持的地址类型（atyp=9）：回 address_type_not_supported（0x05 0x08 …）。
    {
        const fd = try connectLocal(port);
        defer closeFd(fd);
        try writeAllFd(fd, &[_]u8{ 5, 1, 0 });
        var method_reply: [2]u8 = undefined;
        try readExact(fd, &method_reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 0 }, &method_reply);

        try writeAllFd(fd, &[_]u8{ 5, 1, 0, 9, 1, 2, 3, 0, 80 });
        var reply: [10]u8 = undefined;
        try readExact(fd, &reply, handshake_guard_ms);
        try std.testing.expectEqualSlices(u8, &.{ 5, 8, 0, 1, 0, 0, 0, 0, 0, 0 }, &reply);
    }

    try waitForIdle(listener);
    try std.testing.expectEqual(@as(u64, 4), listener.stats().connections_total);
    listener.stop();
}

test "listener stop interrupts an accepted incomplete greeting and releases its port" {
    const listener = try Socks5Listener.init(std.testing.allocator, null);
    defer listener.deinit();
    try listener.start(0);
    const port = listener.port();
    const fd = try connectLocal(port);
    defer closeFd(fd);
    // The real accepted socket waits for the second greeting byte.
    try writeAllFd(fd, &.{5});
    const deadline = clock.monotonicNs() + 2 * std.time.ns_per_s;
    while (listener.stats().connections_active != 1) {
        if (clock.monotonicNs() >= deadline) return error.ClientWasNotAccepted;
        sleepMs(1);
    }
    const started = clock.monotonicNs();
    listener.stop();
    const elapsed = clock.monotonicNs() - started;
    try std.testing.expect(elapsed < 500 * std.time.ns_per_ms);
    try std.testing.expectEqual(ListenerState.off, listener.state());
    try std.testing.expectEqual(@as(u32, 0), listener.stats().connections_active);
    try expectClosedByPeer(fd);
    // Reuse proves the real listening descriptor was closed before return.
    try listener.start(port);
    try std.testing.expectEqual(port, listener.port());
    listener.stop();
}

test "listener admission cap rejects excess sockets and returns the slot after close" {
    const listener = try Socks5Listener.init(std.testing.allocator, null);
    defer listener.deinit();
    try listener.startWithOptions(.{ .requested_port = 0, .max_connections = 1 });
    const first = try connectLocal(listener.port());
    var first_open = true;
    defer if (first_open) closeFd(first);
    try writeAllFd(first, &.{ 5, 1, 0 });
    var method: [2]u8 = undefined;
    try readExact(first, &method, handshake_guard_ms);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0 }, &method);
    const denied = try connectLocal(listener.port());
    defer closeFd(denied);
    try expectClosedByPeer(denied);
    try std.testing.expectEqual(@as(u32, 1), listener.stats().connections_active);
    closeFd(first);
    first_open = false;
    try waitForIdle(listener);
    const next = try connectLocal(listener.port());
    defer closeFd(next);
    try writeAllFd(next, &.{ 5, 1, 0 });
    try readExact(next, &method, handshake_guard_ms);
    try std.testing.expectEqualSlices(u8, &.{ 5, 0 }, &method);
    try std.testing.expectEqual(@as(u64, 2), listener.stats().connections_total);
    listener.stop();
    try std.testing.expectEqual(@as(u32, 0), listener.stats().connections_active);
}
