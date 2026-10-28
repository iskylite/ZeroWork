//! Bounded diagnostic logging. Producers only format/copy fixed-size records;
//! a detached owner performs all filesystem and stderr IO using its own Io.
const std = @import("std");
const builtin = @import("builtin");
const Paths = @import("../config/paths.zig").Paths;
const Wakeup = @import("wakeup.zig").Wakeup;
const allocator = std.heap.page_allocator;
const record_bytes = 2048;
const queue_limit = 256;
const close_budget_ms = 200;

pub const Level = enum(u8) {
    debug,
    info,
    warn,
    err,
    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }
};
pub const Module = enum { app, ui, workspace, ssh, vt, transfer, ai, config };
pub const Config = struct {
    dir: ?[]const u8 = null,
    max_bytes: u64 = 8 * 1024 * 1024,
    keep_days: u32 = 7,
    min_level: Level = .debug,
    queue_capacity: u16 = queue_limit,
    important_reserve: u16 = 32,
    mirror_stderr: bool = true,
};
pub const CloseReceipt = enum { released, awaiting };
pub const FlushResult = enum { pending, complete, failed, closed };
pub const FlushTicket = struct { generation: u64, through: u64 };
pub const Stage = enum(u8) { starting, idle, disk, stderr, syncing, closing, done };
pub const Stats = struct {
    busy: bool = false,
    active: bool = false,
    closing: bool = false,
    generation: u64 = 0,
    queued: usize = 0,
    accepted: u64 = 0,
    processed: u64 = 0,
    dropped: [4]u64 = @splat(0),
    contention_drops: u64 = 0,
    disk_failed: bool = false,
    stderr_failed: bool = false,
    stage: Stage = .done,
};
const Record = struct { bytes: [record_bytes]u8 = undefined, len: usize = 0, level: Level = .info, sequence: u64 = 0 };
// Failure/slow-IO injection exists only in test binaries, with no production hook.
const TestHooks = if (builtin.is_test) struct {
    context: *anyopaque,
    before_write: ?*const fn (*anyopaque, std.Io.File) void = null,
} else void;
const Logger = struct {
    wake: Wakeup,
    config: Config,
    directory: [512]u8 = undefined,
    directory_len: usize,
    path: [640]u8 = undefined,
    path_len: usize,
    generation: u64,
    started_ms: i64,
    stderr_fd: c_int = -1,
    mutex: std.atomic.Mutex = .unlocked,
    records: [queue_limit]Record = undefined,
    head: usize = 0,
    count: usize = 0,
    accepted: u64 = 0,
    flush_requested: u64 = 0,
    flush_pending: bool = false,
    processed: std.atomic.Value(u64) = .init(0),
    flushed: std.atomic.Value(u64) = .init(0),
    synced_once: std.atomic.Value(bool) = .init(false),
    dropped: [4]std.atomic.Value(u64) = @splat(.init(0)),
    disk_failed: std.atomic.Value(bool) = .init(false),
    stderr_failed: std.atomic.Value(bool) = .init(false),
    stage: std.atomic.Value(Stage) = .init(.starting),
    stopping: std.atomic.Value(bool) = .init(false),
    stop_deadline_ms: i64 = 0, // published by stopping's release store
    done: std.atomic.Value(bool) = .init(false),
    test_hooks: ?*const TestHooks = null,
    fn notify(self: *Logger) void {
        // One best-effort nonblocking syscall; even EINTR cannot make a
        // producer loop. The writer's bounded poll is a fallback wakeup.
        _ = std.c.write(self.wake.write_fd, "w", 1);
    }
    const Pop = union(enum) { busy, empty, record: Record };
    fn pop(self: *Logger) Pop {
        if (!self.mutex.tryLock()) return .busy;
        defer self.mutex.unlock();
        if (self.count == 0) return .empty;
        const record = self.records[self.head];
        self.head = (self.head + 1) % self.config.queue_capacity;
        self.count -= 1;
        return .{ .record = record };
    }
    fn destroy(self: *Logger) void {
        std.debug.assert(self.done.load(.acquire));
        self.wake.deinit();
        allocator.destroy(self);
    }
};
var state: struct {
    mutex: std.atomic.Mutex = .unlocked,
    active: ?*Logger = null,
    closing: ?*Logger = null,
    generation: u64 = 0,
    published_generation: std.atomic.Value(u64) = .init(0),
    enabled: std.atomic.Value(bool) = .init(false),
    min_level: std.atomic.Value(Level) = .init(.debug),
    started_ms: std.atomic.Value(i64) = .init(0),
    contention_drops: std.atomic.Value(u64) = .init(0),
} = .{};

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}
fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}
fn pause() void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// Kept source-compatible with callers. The borrowed Io is deliberately never
/// retained: a slow writer may outlive shutdown's deadline and the caller's Io.
pub fn init(config: Config, _: std.Io) void {
    start(config, null);
}
fn start(config: Config, test_hooks: ?*const TestHooks) void {
    if (!state.mutex.tryLock()) return;
    defer state.mutex.unlock();
    if (state.active != null) return;
    if (state.closing) |old| {
        if (!old.done.load(.acquire)) return; // at most one live writer
        old.destroy();
        state.closing = null;
    }
    var paths: ?Paths = null;
    defer if (paths) |*value| value.deinit();
    const directory = config.dir orelse blk: {
        paths = Paths.forApplication(allocator) catch return;
        break :blk paths.?.diagnostic_directory;
    };
    if (directory.len > 512 or !std.fs.path.isAbsolute(directory)) return;
    const logger = allocator.create(Logger) catch return;
    const wake = Wakeup.init() catch {
        allocator.destroy(logger);
        return;
    };
    state.generation = std.math.add(u64, state.generation, 1) catch {
        var owned = wake;
        owned.deinit();
        allocator.destroy(logger);
        return;
    };
    const capacity = std.math.clamp(config.queue_capacity, 1, queue_limit);
    logger.* = .{ .wake = wake, .config = config, .directory_len = directory.len, .path_len = 0, .generation = state.generation, .started_ms = nowMs(), .test_hooks = test_hooks };
    logger.config.dir = null; // only the owned directory buffer may cross threads
    logger.config.queue_capacity = capacity;
    logger.config.important_reserve = @min(config.important_reserve, capacity - 1);
    @memcpy(logger.directory[0..directory.len], directory);
    var name_buffer: [96]u8 = undefined;
    const name = timestampName(&name_buffer, logger.generation);
    const path = std.fmt.bufPrint(&logger.path, "{s}/{s}", .{ directory, name }) catch unreachable;
    logger.path_len = path.len;
    if (config.mirror_stderr) {
        logger.stderr_fd = std.c.dup(std.c.STDERR_FILENO);
        if (logger.stderr_fd >= 0) {
            if (std.c.fcntl(logger.stderr_fd, std.c.F.SETFD, @as(c_int, 1)) < 0 or
                std.c.fcntl(logger.stderr_fd, std.c.F.SETNOSIGPIPE, @as(c_int, 1)) < 0)
            {
                _ = std.c.close(logger.stderr_fd);
                logger.stderr_fd = -1;
                logger.stderr_failed.store(true, .release);
            }
        }
    }
    const thread = std.Thread.spawn(.{}, run, .{logger}) catch {
        if (logger.stderr_fd >= 0) _ = std.c.close(logger.stderr_fd);
        logger.done.store(true, .release);
        logger.destroy();
        return;
    };
    thread.detach();
    state.active = logger;
    state.published_generation.store(logger.generation, .release);
    state.min_level.store(config.min_level, .release);
    state.started_ms.store(logger.started_ms, .release);
    state.enabled.store(true, .release);
}

pub fn enabled(level: Level) bool {
    return state.enabled.load(.acquire) and @backingInt(level) >= @backingInt(state.min_level.load(.acquire));
}
fn format(record: *Record, started_ms: i64, level: Level, module: Module, comptime fmt: []const u8, args: anytype) void {
    record.level = level;
    var stream = std.Io.Writer.fixed(record.bytes[0 .. record_bytes - 1]);
    const total_ms = nowMs();
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(@max(total_ms, 0), 1000)) };
    const day = epoch.getDaySeconds();
    stream.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} +{d}ms {s} {s}] ", .{ day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute(), @as(u64, @intCast(@mod(total_ms, 1000))), total_ms - started_ms, level.label(), @tagName(module) }) catch {};
    stream.print(fmt, args) catch {
        const suffix = " [truncated]";
        const end = @max(stream.buffered().len, suffix.len);
        @memcpy(record.bytes[end - suffix.len .. end], suffix);
        record.len = end;
        record.bytes[record.len] = '\n';
        record.len += 1;
        return;
    };
    record.len = stream.buffered().len;
    record.bytes[record.len] = '\n';
    record.len += 1;
}

/// No allocation, IO sink calls or waiting for a lock on a producer thread.
/// Accepted records retain FIFO order; rejected records are explicitly counted.
pub fn write(level: Level, module: Module, comptime fmt: []const u8, args: anytype) void {
    const generation = state.published_generation.load(.acquire);
    if (!enabled(level)) return;
    var record: Record = .{};
    format(&record, state.started_ms.load(.acquire), level, module, fmt, args);
    if (!state.mutex.tryLock()) {
        _ = state.contention_drops.fetchAdd(1, .monotonic);
        return;
    }
    defer state.mutex.unlock();
    const logger = state.active orelse return;
    if (logger.generation != generation) return; // a retired producer cannot enter a new sink
    if (!logger.mutex.tryLock()) {
        _ = logger.dropped[@backingInt(level)].fetchAdd(1, .monotonic);
        return;
    }
    defer logger.mutex.unlock();
    const limit = if (@backingInt(level) < @backingInt(Level.warn)) logger.config.queue_capacity - logger.config.important_reserve else logger.config.queue_capacity;
    if (logger.count >= limit) {
        _ = logger.dropped[@backingInt(level)].fetchAdd(1, .monotonic);
        return;
    }
    logger.accepted += 1;
    record.sequence = logger.accepted;
    logger.records[(logger.head + logger.count) % logger.config.queue_capacity] = record;
    logger.count += 1;
    logger.notify();
}
pub fn debug(module: Module, comptime fmt: []const u8, args: anytype) void {
    write(.debug, module, fmt, args);
}
pub fn info(module: Module, comptime fmt: []const u8, args: anytype) void {
    write(.info, module, fmt, args);
}
pub fn warn(module: Module, comptime fmt: []const u8, args: anytype) void {
    write(.warn, module, fmt, args);
}
pub fn err(module: Module, comptime fmt: []const u8, args: anytype) void {
    write(.err, module, fmt, args);
}

/// Initiate and poll close without joining. Destructive data cleanup must wait
/// for released, since a timed-out kernel IO still owns its path/descriptors.
pub fn shutdownStep() CloseReceipt {
    if (!state.mutex.tryLock()) return .awaiting;
    defer state.mutex.unlock();
    if (state.active) |logger| {
        state.active = null;
        state.closing = logger;
        state.enabled.store(false, .release);
        logger.stop_deadline_ms = monotonicMs() + close_budget_ms;
        logger.stopping.store(true, .release);
        logger.notify();
    }
    const logger = state.closing orelse return .released;
    if (!logger.done.load(.acquire)) return .awaiting;
    logger.destroy();
    state.closing = null;
    return .released;
}
/// Final-process best effort, bounded even when a kernel call never returns.
/// The detached owner retains its own Io/resources; no cancellation/free race.
pub fn shutdown() void {
    for (0..close_budget_ms) |_| {
        if (shutdownStep() == .released) return;
        pause();
    }
}

pub fn requestFlush() ?FlushTicket {
    if (!state.mutex.tryLock()) return null;
    defer state.mutex.unlock();
    const logger = state.active orelse return null;
    if (!logger.mutex.tryLock()) return null;
    defer logger.mutex.unlock();
    logger.flush_requested = logger.accepted;
    logger.flush_pending = true;
    logger.notify();
    return .{ .generation = logger.generation, .through = logger.accepted };
}
pub fn pollFlush(ticket: FlushTicket) FlushResult {
    if (!state.mutex.tryLock()) return .pending;
    defer state.mutex.unlock();
    const logger = state.active orelse state.closing orelse return .closed;
    if (logger.generation != ticket.generation) return .closed;
    if (logger.disk_failed.load(.acquire)) return .failed;
    if (logger.synced_once.load(.acquire) and logger.flushed.load(.acquire) >= ticket.through) return .complete;
    if (logger.done.load(.acquire)) return .closed;
    return .pending;
}
/// Optional bounded wait for CLI/tests; UI uses requestFlush/pollFlush instead.
pub fn flush(timeout_ms: u32) FlushResult {
    var ticket: ?FlushTicket = null;
    for (0..@as(usize, timeout_ms) + 1) |i| {
        if (ticket == null) {
            ticket = requestFlush();
            if (ticket == null) {
                const current = snapshot();
                if (!current.busy and !current.active) return .closed;
            }
        }
        if (ticket) |value| {
            const result = pollFlush(value);
            if (result != .pending) return result;
        }
        if (i != timeout_ms) pause();
    }
    return .pending;
}
pub fn snapshot() Stats {
    if (!state.mutex.tryLock()) return .{ .busy = true };
    defer state.mutex.unlock();
    const logger = state.active orelse state.closing orelse return .{ .contention_drops = state.contention_drops.load(.acquire) };
    var result: Stats = .{ .active = state.active != null, .closing = state.closing != null, .generation = logger.generation, .processed = logger.processed.load(.acquire), .disk_failed = logger.disk_failed.load(.acquire), .stderr_failed = logger.stderr_failed.load(.acquire), .stage = logger.stage.load(.acquire), .contention_drops = state.contention_drops.load(.acquire) };
    for (&result.dropped, &logger.dropped) |*out, *counter| out.* = counter.load(.acquire);
    if (logger.mutex.tryLock()) {
        result.queued = logger.count;
        result.accepted = logger.accepted;
        logger.mutex.unlock();
    } else result.busy = true;
    return result;
}

const Sink = struct {
    logger: *Logger,
    io: std.Io,
    file: ?std.Io.File = null,
    bytes: u64 = 0,
    fn disable(self: *Sink) void {
        self.logger.disk_failed.store(true, .release);
        if (self.file) |file| file.close(self.io);
        self.file = null;
    }
    fn emit(self: *Sink, record: *const Record) void {
        if (self.file) |file| {
            self.logger.stage.store(.disk, .release);
            if (builtin.is_test) if (self.logger.test_hooks) |hooks| if (hooks.before_write) |hook| hook(hooks.context, file);
            if (self.bytes + record.len > self.logger.config.max_bytes) self.rotate();
            if (self.file) |active| {
                if (active.writePositionalAll(self.io, record.bytes[0..record.len], self.bytes)) {
                    self.bytes += record.len;
                } else |_| self.disable();
            }
        }
        if (self.logger.stderr_fd >= 0 and @backingInt(record.level) >= @backingInt(Level.warn)) {
            self.logger.stage.store(.stderr, .release);
            var offset: usize = 0;
            while (offset < record.len) {
                const count = std.c.write(self.logger.stderr_fd, record.bytes[offset..record.len].ptr, record.len - offset);
                if (count < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
                if (count <= 0) {
                    self.logger.stderr_failed.store(true, .release);
                    _ = std.c.close(self.logger.stderr_fd);
                    self.logger.stderr_fd = -1;
                    break;
                }
                offset += @intCast(count);
            }
        }
    }
    fn rotate(self: *Sink) void {
        const file = self.file orelse return;
        file.close(self.io);
        self.file = null;
        const path = self.logger.path[0..self.logger.path_len];
        var buffer: [642]u8 = undefined;
        const archive = std.fmt.bufPrint(&buffer, "{s}.1", .{path}) catch {
            self.disable();
            return;
        };
        std.Io.Dir.renameAbsolute(path, archive, self.io) catch {
            self.disable();
            return;
        };
        self.file = std.Io.Dir.createFileAbsolute(self.io, path, .{ .exclusive = true, .permissions = @fromBackingInt(0o600) }) catch {
            self.disable();
            return;
        };
        self.bytes = 0;
    }
    fn sync(self: *Sink) void {
        self.logger.stage.store(.syncing, .release);
        if (self.file) |file| file.sync(self.io) catch {
            self.disable();
            return;
        };
    }
    fn dropSummary(self: *Sink, reported: *[5]u64) void {
        var dropped: [5]u64 = undefined;
        for (&self.logger.dropped, 0..) |*counter, i| dropped[i] = counter.load(.acquire);
        dropped[4] = state.contention_drops.load(.acquire);
        if (std.mem.eql(u64, &dropped, reported)) return;
        var record: Record = .{};
        format(&record, self.logger.started_ms, .warn, .app, "log queue dropped debug={d} info={d} warn={d} error={d} contention={d} (totals)", .{ dropped[0], dropped[1], dropped[2], dropped[3], dropped[4] });
        reported.* = dropped;
        self.emit(&record); // never recurse into the producer/queue
    }
};
fn run(logger: *Logger) void {
    // Independent lifetime: shutdown may return while this stack owns a slow
    // syscall. Never refer to main's borrowed Io or a producer's stack buffers.
    var threaded = std.Io.Threaded.init(allocator, .{});
    runOwned(logger, threaded.io());
    threaded.deinit();
    logger.stage.store(.done, .release);
    logger.done.store(true, .release); // last access; controller may now free
}
fn runOwned(logger: *Logger, io: std.Io) void {
    var sink: Sink = .{ .logger = logger, .io = io };
    defer {
        logger.stage.store(.closing, .release);
        if (sink.file != null) {
            sink.sync();
            if (sink.file) |active| active.close(io);
        }
        if (logger.stderr_fd >= 0) _ = std.c.close(logger.stderr_fd);
    }
    if (logger.stopping.load(.acquire)) return;
    const directory = logger.directory[0..logger.directory_len];
    std.Io.Dir.cwd().createDirPath(io, directory) catch {
        logger.disk_failed.store(true, .release);
    };
    if (!logger.disk_failed.load(.acquire)) {
        pruneOldLogs(io, directory, logger.config.keep_days) catch {};
        sink.file = std.Io.Dir.createFileAbsolute(io, logger.path[0..logger.path_len], .{ .exclusive = true, .permissions = @fromBackingInt(0o600) }) catch blk: {
            logger.disk_failed.store(true, .release);
            break :blk null;
        };
    }
    var record: Record = .{};
    format(&record, logger.started_ms, .info, .app, "=== ZeroWork log started === pid={d} generation={d}", .{ std.c.getpid(), logger.generation });
    sink.emit(&record);
    var reported: [5]u64 = @splat(0);
    while (true) {
        if (logger.stopping.load(.acquire) and monotonicMs() >= logger.stop_deadline_ms) {
            if (!logger.mutex.tryLock()) {
                pause();
                continue;
            }
            {
                while (logger.count != 0) {
                    const level = logger.records[logger.head].level;
                    _ = logger.dropped[@backingInt(level)].fetchAdd(1, .monotonic);
                    logger.head = (logger.head + 1) % logger.config.queue_capacity;
                    logger.count -= 1;
                }
                logger.mutex.unlock();
            }
            sink.dropSummary(&reported);
            return;
        }
        switch (logger.pop()) {
            .busy => {
                pause();
                continue;
            },
            .record => |next| {
                sink.emit(&next);
                logger.processed.store(next.sequence, .release);
                if (next.sequence % 32 == 0) sink.dropSummary(&reported);
            },
            .empty => {
                sink.dropSummary(&reported);
                if (logger.stopping.load(.acquire)) return;
                logger.stage.store(.idle, .release);
                logger.wake.wait(-1, false, 20);
            },
        }
        if (logger.mutex.tryLock()) {
            const target = logger.flush_requested;
            const ready = logger.flush_pending and logger.processed.load(.acquire) >= target;
            if (ready) logger.flush_pending = false;
            logger.mutex.unlock();
            if (ready) {
                sink.dropSummary(&reported);
                sink.sync();
                if (!logger.disk_failed.load(.acquire)) {
                    logger.flushed.store(target, .release);
                    logger.synced_once.store(true, .release);
                }
            }
        }
    }
}
fn timestampName(buffer: *[96]u8, generation: u64) []const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divFloor(@max(nowMs(), 0), 1000)) };
    const date = epoch.getEpochDay().calculateYearDay();
    const month = date.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "app-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d}-{d}.log", .{ date.year, month.month.numeric(), month.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute(), std.c.getpid(), generation }) catch "app-unknown.log";
}

fn pruneOldLogs(io: std.Io, dir_path: []const u8, keep_days: u32) !void {
    // 删除 N 天前的 app-*.log（按文件名中的日期，不依赖 mtime）。
    if (keep_days == 0) return;
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    const now = nowMs();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "app-")) continue;
        // app-YYYYMMDD-HHMMSS.log → 解析日期
        if (entry.name.len < "app-YYYYMMDD".len) continue;
        const y = std.fmt.parseInt(i64, entry.name[4..8], 10) catch continue;
        const mo = std.fmt.parseInt(i64, entry.name[8..10], 10) catch continue;
        const d = std.fmt.parseInt(i64, entry.name[10..12], 10) catch continue;
        // 粗略天数差（夏令时误差可忽略）
        const file_days = y * 365 + mo * 31 + d;
        const now_secs: i64 = @divFloor(now, 1000);
        const now_epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(now_secs, 0)) };
        const yd = now_epoch.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const now_days: i64 = @as(i64, yd.year) * 365 + @as(i64, md.month.numeric()) * 31 + @as(i64, md.day_index + 1);
        if (now_days - file_days > keep_days) {
            dir.deleteFile(io, entry.name) catch {};
        }
    }
}

fn testSnapshot() Stats {
    for (0..2000) |_| {
        const value = snapshot();
        if (!value.busy) return value;
        pause();
    }
    @panic("test snapshot remained busy");
}

// Tests exercise real files and real full pipes. Slow storage uses a gate
// inside the owning thread; no producer borrows the fixture's IO or bytes.
const TestDir = struct {
    tmp: std.testing.TmpDir,
    directory: [:0]u8,
    fn init() !TestDir {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator) };
    }
    fn deinit(self: *TestDir) void {
        shutdown();
        std.debug.assert(shutdownStep() == .released);
        std.testing.allocator.free(self.directory);
        self.tmp.cleanup();
    }
    fn config(self: *TestDir) Config {
        return .{ .dir = self.directory, .keep_days = 0, .mirror_stderr = false };
    }
    fn read(self: *TestDir, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .limited(1024 * 1024));
    }
};
const Gate = struct {
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    fn block(raw: *anyopaque, _: std.Io.File) void {
        const self: *Gate = @ptrCast(@alignCast(raw));
        if (self.entered.swap(true, .acq_rel)) return;
        while (!self.released.load(.acquire)) pause();
    }
    fn wait(self: *Gate) !void {
        for (0..2000) |_| {
            if (self.entered.load(.acquire)) return;
            pause();
        }
        return error.GateNotEntered;
    }
};
fn waitFlush(ticket: FlushTicket) !void {
    for (0..2000) |_| {
        switch (pollFlush(ticket)) {
            .complete => return,
            .pending => pause(),
            else => return error.FlushFailed,
        }
    }
    return error.FlushTimedOut;
}
fn releaseWriter(gate: *Gate) void {
    gate.released.store(true, .release);
    shutdown();
    for (0..2000) |_| {
        if (shutdownStep() == .released) return;
        pause();
    }
    @panic("test writer failed to release");
}
fn currentName(buffer: []u8) []const u8 {
    const logger = state.active.?;
    const name = std.fs.path.basename(logger.path[0..logger.path_len]);
    @memcpy(buffer[0..name.len], name);
    return buffer[0..name.len];
}

test "async log queue reserves errors owns bytes and reports overflow after slow storage" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var gate: Gate = .{};
    const hooks: TestHooks = .{ .context = &gate, .before_write = Gate.block };
    var config = dir.config();
    config.queue_capacity = 8;
    config.important_reserve = 2;
    start(config, &hooks);
    defer releaseWriter(&gate);
    try gate.wait();
    var name_buffer: [96]u8 = undefined;
    const name = currentName(&name_buffer);
    const started = monotonicMs();
    var borrowed = "owned-original".*;
    info(.ui, "{s}", .{&borrowed});
    @memset(&borrowed, 'x');
    for (0..5) |i| info(.ui, "low {d}", .{i});
    for (0..1000) |_| info(.ui, "overflow", .{});
    err(.ssh, "important one", .{});
    warn(.ssh, "important two", .{});
    err(.ssh, "overflow important", .{});
    try std.testing.expect(monotonicMs() - started < 200);
    const stats = testSnapshot();
    try std.testing.expectEqual(@as(usize, 8), stats.queued);
    try std.testing.expectEqual(@as(u64, 1000), stats.dropped[1]);
    try std.testing.expectEqual(@as(u64, 1), stats.dropped[3]);
    const ticket = requestFlush().?;
    try std.testing.expectEqual(FlushResult.pending, pollFlush(ticket));
    gate.released.store(true, .release);
    try waitFlush(ticket);
    const bytes = try dir.read(name);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "owned-original") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "important one") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "important two") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "log queue dropped") != null);
}

test "async logger shutdown has a deadline retains blocked IO and never uses caller IO after teardown" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var gate: Gate = .{};
    const hooks: TestHooks = .{ .context = &gate, .before_write = Gate.block };
    var caller_io = std.Io.Threaded.init(allocator, .{});
    start(dir.config(), &hooks); // same start as init, with a controlled disk gate
    init(dir.config(), caller_io.io()); // duplicate init cannot replace the owner
    caller_io.deinit();
    defer releaseWriter(&gate);
    try gate.wait();
    info(.ui, "pending at exit", .{});
    const ticket = requestFlush().?;
    const generation = testSnapshot().generation;
    const started = monotonicMs();
    shutdown();
    try std.testing.expect(monotonicMs() - started < 500);
    try std.testing.expectEqual(CloseReceipt.awaiting, shutdownStep());
    try std.testing.expectEqual(FlushResult.pending, pollFlush(ticket));
    try std.testing.expect(testSnapshot().closing);
    init(dir.config(), std.testing.io);
    try std.testing.expectEqual(generation, testSnapshot().generation);
    try std.testing.expect(!testSnapshot().active);
    gate.released.store(true, .release);
    const retained = state.closing.?;
    for (0..2000) |_| {
        if (retained.done.load(.acquire)) break;
        pause();
    }
    try std.testing.expect(retained.done.load(.acquire));
    try std.testing.expectEqual(FlushResult.closed, pollFlush(ticket));
    releaseWriter(&gate);
    try std.testing.expectEqual(FlushResult.closed, pollFlush(ticket));
    // Only a real release grants deletion; later writes cannot recreate data.
    var iterator = dir.tmp.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| try dir.tmp.dir.deleteFile(std.testing.io, entry.name);
    warn(.app, "after shutdown", .{});
    try std.testing.expectEqual(FlushResult.closed, flush(1000));
    iterator = dir.tmp.dir.iterate();
    try std.testing.expect(try iterator.next(std.testing.io) == null);
}

test "async log flush boundary rotation and failed rename preserve original evidence" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var config = dir.config();
    config.max_bytes = 512;
    init(config, std.testing.io);
    var name_buffer: [96]u8 = undefined;
    const name = currentName(&name_buffer);
    for (0..20) |i| {
        info(.app, "record {d}", .{i});
        try std.testing.expectEqual(FlushResult.complete, flush(1000));
    }
    const bytes = try dir.read(name);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "record 19\n") != null);
    const archive = try std.fmt.allocPrint(std.testing.allocator, "{s}.1", .{name});
    defer std.testing.allocator.free(archive);
    const previous = try dir.read(archive);
    defer std.testing.allocator.free(previous);
    try std.testing.expect(previous.len > 0 and previous.len <= 512);
    try dir.tmp.dir.deleteFile(std.testing.io, archive);
    try dir.tmp.dir.createDir(std.testing.io, archive, .default_dir);
    // The next oversized line requires rotation, whose target is a directory.
    var large: [700]u8 = @splat('F');
    info(.app, "{s}", .{&large});
    try std.testing.expectEqual(FlushResult.failed, flush(1000));
    for (0..100) |_| info(.app, "no repeated disk attempts", .{});
    shutdown();
    const retained = try dir.read(name);
    defer std.testing.allocator.free(retained);
    try std.testing.expectEqualStrings(bytes, retained);
}

test "async log producers do not wait on queue locks and concurrent accounting is bounded" {
    var dir = try TestDir.init();
    defer dir.deinit();
    init(dir.config(), std.testing.io);
    const logger = state.active.?;
    const baseline = testSnapshot().contention_drops;
    try std.testing.expect(state.mutex.tryLock());
    info(.app, "lifecycle contention", .{});
    state.mutex.unlock();
    try std.testing.expect(logger.mutex.tryLock());
    info(.app, "queue contention", .{});
    logger.mutex.unlock();
    try std.testing.expectEqual(baseline + 1, testSnapshot().contention_drops);
    const Producer = struct {
        fn run(id: usize) void {
            for (0..200) |i| info(.ssh, "producer {d} record {d}", .{ id, i });
        }
    };
    const first = try std.Thread.spawn(.{}, Producer.run, .{0});
    const second = std.Thread.spawn(.{}, Producer.run, .{1}) catch |spawn_error| {
        first.join();
        return spawn_error;
    };
    first.join();
    second.join();
    try std.testing.expectEqual(FlushResult.complete, flush(1000));
    const stats = testSnapshot();
    try std.testing.expect(stats.queued <= queue_limit);
    try std.testing.expectEqual(@as(u64, 402), stats.accepted + stats.dropped[1] + stats.contention_drops - baseline);
    try std.testing.expectEqual(stats.accepted, stats.processed);
}

test "async log write errors stop disk retries and truncated records remain bounded" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const read_only = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_only });
    defer read_only.close(std.testing.io);
    const Failure = struct {
        fd: c_int,
        calls: std.atomic.Value(u32) = .init(0),
        fn inject(raw: *anyopaque, file: std.Io.File) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.calls.fetchAdd(1, .monotonic) == 0) _ = std.c.dup2(self.fd, file.handle);
        }
    };
    var failure: Failure = .{ .fd = read_only.handle };
    const hooks: TestHooks = .{ .context = &failure, .before_write = Failure.inject };
    start(dir.config(), &hooks);
    defer shutdown();
    info(.app, "will fail", .{});
    try std.testing.expectEqual(FlushResult.failed, flush(1000));
    for (0..100) |_| info(.app, "already disabled", .{});
    shutdown();
    try std.testing.expectEqual(@as(u32, 1), failure.calls.load(.acquire));
    var record: Record = .{};
    var large: [10000]u8 = @splat('X');
    format(&record, nowMs(), .err, .app, "{s}", .{&large});
    try std.testing.expect(record.len <= record_bytes);
    try std.testing.expect(std.mem.endsWith(u8, record.bytes[0..record.len], " [truncated]\n"));
}

fn fillPipe() ![2]c_int {
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    const flags = std.c.fcntl(fds[1], std.c.F.GETFL);
    const nonblock: std.c.O = .{ .NONBLOCK = true };
    _ = std.c.fcntl(fds[1], std.c.F.SETFL, flags | @as(c_int, @bitCast(nonblock)));
    var bytes: [4096]u8 = @splat('P');
    while (std.c.write(fds[1], &bytes, bytes.len) > 0) {}
    _ = std.c.fcntl(fds[1], std.c.F.SETFL, flags);
    return fds;
}
fn startWithStderr(config: Config, fd: c_int) !void {
    const original = std.c.dup(std.c.STDERR_FILENO);
    if (original < 0) return error.DupFailed;
    defer _ = std.c.close(original);
    if (std.c.dup2(fd, std.c.STDERR_FILENO) < 0) return error.DupFailed;
    defer _ = std.c.dup2(original, std.c.STDERR_FILENO);
    init(config, std.testing.io); // writer owns its own duplicate
}

test "async log full stderr pipe cannot block producers flush polling or shutdown" {
    var dir = try TestDir.init();
    defer dir.deinit();
    const pipe = try fillPipe();
    var read_open = true;
    defer if (read_open) {
        _ = std.c.close(pipe[0]);
    };
    defer _ = std.c.close(pipe[1]);
    var config = dir.config();
    config.mirror_stderr = true;
    try startWithStderr(config, pipe[1]);
    var released = false;
    defer if (!released) {
        _ = std.c.close(pipe[0]);
        read_open = false;
        shutdown();
    };
    warn(.ui, "blocked mirror", .{});
    for (0..2000) |_| {
        if (testSnapshot().stage == .stderr) break;
        pause();
    }
    try std.testing.expectEqual(Stage.stderr, testSnapshot().stage);
    const ticket = requestFlush().?;
    const started = monotonicMs();
    for (0..1000) |_| info(.ui, "UI continues", .{});
    try std.testing.expectEqual(FlushResult.pending, pollFlush(ticket));
    shutdown();
    try std.testing.expect(monotonicMs() - started < 500);
    try std.testing.expectEqual(CloseReceipt.awaiting, shutdownStep());
    // Drain enough of the real pipe for the blocked write to complete.
    var bytes: [4096]u8 = undefined;
    _ = std.c.read(pipe[0], &bytes, bytes.len);
    for (0..2000) |_| {
        if (shutdownStep() == .released) {
            released = true;
            break;
        }
        pause();
    }
    try std.testing.expect(released);
    try std.testing.expectEqual(FlushResult.closed, pollFlush(ticket));
}

test "async log closed stderr reader does not raise SIGPIPE or prevent disk flush" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var pipe: [2]c_int = undefined;
    if (std.c.pipe(&pipe) != 0) return error.PipeFailed;
    _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);
    var config = dir.config();
    config.mirror_stderr = true;
    try startWithStderr(config, pipe[1]);
    err(.ssh, "closed output pipe", .{});
    try std.testing.expectEqual(FlushResult.complete, flush(1000));
    try std.testing.expect(testSnapshot().stderr_failed);
}

test "async log level filtering empty flush and generation tickets remain valid across restart" {
    var dir = try TestDir.init();
    defer dir.deinit();
    var gate: Gate = .{};
    const hooks: TestHooks = .{ .context = &gate, .before_write = Gate.block };
    var config = dir.config();
    config.min_level = .warn;
    start(config, &hooks);
    defer releaseWriter(&gate);
    try gate.wait();
    const generation = testSnapshot().generation;
    try std.testing.expect(!enabled(.info) and enabled(.warn));
    info(.ui, "filtered", .{});
    const empty = requestFlush().?;
    try std.testing.expectEqual(@as(u64, 0), empty.through);
    try std.testing.expectEqual(FlushResult.pending, pollFlush(empty));
    warn(.ui, "accepted warning", .{});
    try std.testing.expectEqual(@as(u64, 1), testSnapshot().accepted);
    init(config, std.testing.io);
    try std.testing.expectEqual(generation, testSnapshot().generation);
    gate.released.store(true, .release);
    try waitFlush(empty);
    try std.testing.expectEqual(FlushResult.complete, flush(1000));
    releaseWriter(&gate);
    init(dir.config(), std.testing.io);
    try std.testing.expect(testSnapshot().generation > generation);
    try std.testing.expectEqual(FlushResult.closed, pollFlush(empty));
    info(.app, "new logger", .{});
    try std.testing.expectEqual(FlushResult.complete, flush(1000));
}

test "async log setup failure does not block callers or retry broken storage" {
    var dir = try TestDir.init();
    defer dir.deinit();
    try dir.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-directory", .data = "evidence" });
    const broken = try std.fs.path.join(std.testing.allocator, &.{ dir.directory, "not-a-directory", "logs" });
    defer std.testing.allocator.free(broken);
    var config = dir.config();
    config.dir = broken;
    init(config, std.testing.io);
    info(.app, "failed setup", .{});
    try std.testing.expectEqual(FlushResult.failed, flush(1000));
    const started = monotonicMs();
    for (0..1000) |_| warn(.app, "disk unavailable", .{});
    try std.testing.expect(monotonicMs() - started < 200);
    shutdown();
    const evidence = try dir.read("not-a-directory");
    defer std.testing.allocator.free(evidence);
    try std.testing.expectEqualStrings("evidence", evidence);
}

test "async log in-flight producer cannot publish into a replacement generation" {
    var dir = try TestDir.init();
    defer dir.deinit();
    init(dir.config(), std.testing.io);
    try std.testing.expectEqual(FlushResult.complete, flush(1000));
    const Producer = struct {
        gate: Gate = .{},
        pub fn format(self: *@This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            self.gate.entered.store(true, .release);
            while (!self.gate.released.load(.acquire)) pause();
            try writer.writeAll("retired producer");
        }
        fn run(self: *@This()) void {
            info(.app, "{f}", .{self});
        }
    };
    var producer: Producer = .{};
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    var joined = false;
    defer if (!joined) {
        producer.gate.released.store(true, .release);
        thread.join();
    };
    try producer.gate.wait();
    shutdown();
    try std.testing.expectEqual(CloseReceipt.released, shutdownStep());
    init(dir.config(), std.testing.io);
    producer.gate.released.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expectEqual(FlushResult.complete, flush(1000));
    try std.testing.expectEqual(@as(u64, 0), testSnapshot().accepted);
}
