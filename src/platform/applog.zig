const std = @import("std");
const Paths = @import("../config/paths.zig").Paths;

/// ZeroWork 内置日志系统。
///
/// 输出到 macOS Library/Logs/com.zerowork.app 的 `app-<启动时间>.log`（与会话数据隔离）。
/// 目标是"能看到每次操作走到哪、断在哪、错在哪"：
///  - 每条日志带毫秒时间戳、级别、模块名，一行一条；
///  - 线程安全（内部自旋锁），worker 线程/UI 线程共用；
///  - 写满 `max_bytes` 后轮转到 `.1`（保留一份旧档），启动时清理过期文件；
///  - 启动时使用固定日志级别，不读取外部开关。
///
/// 用法：`log.info(.ui, "connectHost index={d}", .{index});`
/// 模块约定：ui / workspace / ssh / vt / transfer / ai / config / app。
pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }
};

pub const Module = enum {
    app,
    ui,
    workspace,
    ssh,
    vt,
    transfer,
    ai,
    config,
};

pub const Config = struct {
    /// 日志目录。null = Paths.forApplication().diagnostic_directory。
    dir: ?[]const u8 = null,
    /// 单文件上限，超过后轮转。
    max_bytes: u64 = 8 * 1024 * 1024,
    /// 启动时清理多少天前的旧日志。
    keep_days: u32 = 7,
    min_level: Level = .debug,
};

var state: struct {
    mutex: std.atomic.Mutex = .unlocked,
    io: ?std.Io = null,
    file: ?std.Io.File = null,
    bytes_written: u64 = 0,
    max_bytes: u64 = 0,
    rotated_path: [512]u8 = undefined,
    rotated_len: usize = 0,
    min_level: Level = .debug,
    started_ms: i128 = 0,
    start_clock: i128 = 0,
} = .{};

/// 时间戳（毫秒）。std.time.milliTimestamp 足够，无需平台时钟。
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn ensureDirRecursive(io: std.Io, abs_path: []const u8) !void {
    // 逐级 createDir，忽略已存在错误。abs_path 必须以 '/' 开头。
    var i: usize = 1;
    while (i < abs_path.len) : (i += 1) {
        if (abs_path[i] != '/') continue;
        const partial = abs_path[0..i];
        std.Io.Dir.createDirAbsolute(io, partial, .default_dir) catch |dir_err| switch (dir_err) {
            error.PathAlreadyExists => {},
            else => return dir_err,
        };
    }
    std.Io.Dir.createDirAbsolute(io, abs_path, .default_dir) catch |dir_err| switch (dir_err) {
        error.PathAlreadyExists => {},
        else => return dir_err,
    };
}

/// 初始化日志系统。失败时静默降级为无文件输出（printf 调试通道仍在）。
pub fn init(config: Config, io: std.Io) void {
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();
    state.io = io;
    state.max_bytes = config.max_bytes;
    state.min_level = config.min_level;
    state.started_ms = nowMs();

    var dir_path_buf: [512]u8 = undefined;
    var dir_path: []const u8 = undefined;
    if (config.dir) |explicit| {
        dir_path = explicit;
    } else {
        var paths = Paths.forApplication(std.heap.page_allocator) catch {
            std.log.info("logging disabled: user data directory unavailable", .{});
            return;
        };
        defer paths.deinit();
        if (paths.diagnostic_directory.len > dir_path_buf.len) return;
        @memcpy(dir_path_buf[0..paths.diagnostic_directory.len], paths.diagnostic_directory);
        dir_path = dir_path_buf[0..paths.diagnostic_directory.len];
    }

    ensureDirRecursive(io, dir_path) catch {
        std.log.info("logging disabled: mkdir {s} failed", .{dir_path});
        return;
    };

    // 清理过期日志：文件名含 app- 前缀的才动。
    pruneOldLogs(io, dir_path, config.keep_days) catch {};

    // 文件名：app-YYYYMMDD-HHMMSS.log
    var name_buf: [64]u8 = undefined;
    const name = timestampName(&name_buf);
    var path_buf: [576]u8 = undefined;
    if (dir_path.len + 1 + name.len > path_buf.len) return;
    @memcpy(path_buf[0..dir_path.len], dir_path);
    path_buf[dir_path.len] = '/';
    @memcpy(path_buf[dir_path.len + 1 ..][0..name.len], name);
    const path = path_buf[0 .. dir_path.len + 1 + name.len];

    rememberPath(path);
    const file = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false, .permissions = @fromBackingInt(0o600) }) catch {
        return;
    };
    state.file = file;
    state.bytes_written = 0;

    // writeHeader 在锁外写（init 自己持锁中，info() 会自旋死锁）。
    // 先解锁再写：用标志防止其他线程插队太早也没关系——header 晚几行无碍。
    state.mutex.unlock();
    writeHeader(dir_path, path);
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Stop disk logging before destructive application-data operations. Writers
/// share this mutex, so no write/rotation can retain the closed file handle.
pub fn shutdown() void {
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();
    if (state.file) |file| if (state.io) |io| file.close(io);
    state.file = null;
    state.io = null;
    state.bytes_written = 0;
    state.rotated_len = 0;
    current_file_path_len = 0;
}

fn timestampName(buf: *[64]u8) []const u8 {
    const secs: u64 = @intCast(@max(@divFloor(nowMs(), 1000), 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    const name = std.fmt.bufPrint(buf, "app-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.log", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch return "app-unknown.log";
    return name;
}

fn writeHeader(dir_path: []const u8, path: []const u8) void {
    info(.app, "=== ZeroWork log started ===", .{});
    info(.app, "log dir: {s}", .{dir_path});
    info(.app, "log file: {s}", .{path});
    info(.app, "pid: {d}", .{std.c.getpid()});
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

fn rotateLocked() void {
    const file = state.file orelse return;
    var path_buf: [576]u8 = undefined;
    const current_path = currentPathLocked(&path_buf) orelse {
        file.close(state.io.?);
        state.file = null;
        return;
    };
    file.close(state.io.?);
    state.file = null;

    const rotated = std.fmt.bufPrint(state.rotated_path[0..], "{s}.1", .{current_path}) catch return;
    state.rotated_len = rotated.len;
    const io = state.io orelse return;
    std.Io.Dir.renameAbsolute(current_path, rotated, io) catch {};

    const reopened = std.Io.Dir.createFileAbsolute(io, current_path, .{ .truncate = true, .permissions = @fromBackingInt(0o600) }) catch return;
    state.file = reopened;
    state.bytes_written = 0;
    info(.app, "log rotated (kept {s})", .{rotated});
}

/// 当前日志文件路径需要保存下来才能轮转。init 时记录一次。
var current_file_path: [576]u8 = undefined;
var current_file_path_len: usize = 0;

fn currentPathLocked(buf: []u8) ?[]const u8 {
    if (current_file_path_len == 0 or current_file_path_len > buf.len) return null;
    @memcpy(buf[0..current_file_path_len], current_file_path[0..current_file_path_len]);
    return buf[0..current_file_path_len];
}

/// 是否应输出该级别。
pub fn enabled(level: Level) bool {
    return @backingInt(level) >= @backingInt(state.min_level);
}

/// 核心写入。任何模块错误都不应影响业务：内部全部吞掉。
pub fn write(level: Level, module: Module, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(level)) return;
    while (!state.mutex.tryLock()) std.atomic.spinLoopHint();
    defer state.mutex.unlock();

    var buffer: [2048]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // [HH:MM:SS.mmm LEVEL module] message
    const total_ms = nowMs();
    const since_start = total_ms - @as(i64, @intCast(state.started_ms));
    const secs_total: u64 = @intCast(@divFloor(@max(total_ms, 0), 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs_total };
    const day_secs = epoch.getDaySeconds();
    const ms_part: u64 = @intCast(@mod(total_ms, 1000));

    stream.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} +{d:0>7}ms {s} {s}] ", .{
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        ms_part,
        since_start,
        level.label(),
        @tagName(module),
    }) catch return;
    stream.print(fmt, args) catch return;
    stream.writeByte('\n') catch return;

    const line = stream.buffered();
    if (state.io) |io| {
        if (state.bytes_written + line.len > state.max_bytes) rotateLocked();
        if (state.file) |active| {
            active.writePositionalAll(io, line, state.bytes_written) catch {};
            state.bytes_written += line.len;
        }
    }
    // Mirror warn/err to stderr so terminal runs surface problems immediately.
    if (@backingInt(level) >= @backingInt(Level.warn)) {
        std.debug.print("{s}", .{line});
    }
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

/// init 里记录当前文件路径（rotate 需要）。放最后避免遮蔽上面的使用。
pub fn rememberPath(path: []const u8) void {
    if (path.len > current_file_path.len) return;
    @memcpy(current_file_path[0..path.len], path);
    current_file_path_len = path.len;
}

test "timestamp name format" {
    var buf: [64]u8 = undefined;
    const name = timestampName(&buf);
    try std.testing.expect(std.mem.startsWith(u8, name, "app-"));
    try std.testing.expect(std.mem.endsWith(u8, name, ".log"));
}

test "level filter respects minimum" {
    const saved = state.min_level;
    defer state.min_level = saved;
    state.min_level = .warn;
    try std.testing.expect(!enabled(.debug));
    try std.testing.expect(!enabled(.info));
    try std.testing.expect(enabled(.warn));
    try std.testing.expect(enabled(.err));
}

test "write before init is a no-op and does not crash" {
    // state.file == null → 直接跳过文件写入，不崩溃。
    write(.info, .app, "probe without file {d}", .{1});
}

test "shutdown closes logging and later writes do not recreate files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(directory);
    init(.{ .dir = directory, .keep_days = 0 }, std.testing.io);
    try std.testing.expect(state.file != null);
    shutdown();
    try std.testing.expect(state.file == null);
    try std.testing.expect(state.io == null);
    var iterator = tmp.dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| try tmp.dir.deleteFile(std.testing.io, entry.name);
    write(.info, .app, "after shutdown", .{});
    shutdown();
    iterator = tmp.dir.iterate();
    try std.testing.expect(try iterator.next(std.testing.io) == null);
}
