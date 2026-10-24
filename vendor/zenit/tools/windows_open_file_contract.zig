//! Native startup and cross-process file intent contracts; no foreground input.
const std = @import("std");
const App = @import("zenit_app").App;
const Window = @FieldType(App, "win");
const tag = 0x5a4e4f50;
const first: [:0]const u8 = "C:\\Zenit fixture\\字体 🧪.md";
const second: [:0]const u8 = "C:\\Zenit fixture\\second.md";
extern fn zenit_win_open_path_contract_commandline([*:0]const u16) c_int;
extern fn zenit_win_open_path_contract_raw(*anyopaque, usize, ?[*]const u8, u32) c_int;
extern fn zenit_win_open_path_contract_close(*anyopaque) c_int;
extern "user32" fn GetForegroundWindow() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(*anyopaque, u32) callconv(.winapi) u32;

fn require(ok: bool) !void {
    if (!ok) return error.OpenFileContractFailed;
}
fn empty(win: *Window) !void {
    var buffer: [1]u8 = undefined;
    try require(win.pendingOpenFileRequiredSize() == null and try win.getPendingOpenFile(&buffer) == null);
}
fn take(win: *Window, expected: []const u8) !void {
    const size = win.pendingOpenFileRequiredSize() orelse return error.MissingOpenFile;
    try require(size == expected.len + 1 and win.pendingOpenFileRequiredSize() == size);
    const buffer = try std.heap.page_allocator.alloc(u8, size);
    defer std.heap.page_allocator.free(buffer);
    @memset(buffer, 0xab);
    if (win.getPendingOpenFile(buffer[0..0])) |_| return error.EmptyBufferAccepted else |err| {
        try require(err == error.BufferTooSmall and win.pendingOpenFileRequiredSize() == size);
    }
    if (win.getPendingOpenFile(buffer[0 .. size - 1])) |_| return error.TruncatedOpenFileAccepted else |err| {
        try require(err == error.BufferTooSmall and buffer[0] == 0xab and win.pendingOpenFileRequiredSize() == size);
    }
    const path = (try win.getPendingOpenFile(buffer)) orelse return error.MissingOpenFile;
    try require(path.ptr == buffer.ptr and std.mem.eql(u8, path, expected) and buffer[path.len] == 0);
}
fn parse(line: []const u8, accepted: bool) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, line);
    defer std.heap.page_allocator.free(wide);
    try require((zenit_win_open_path_contract_commandline(wide) == 1) == accepted);
}

pub fn dispatchChild(init: std.process.Init) !bool {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--zenit-open-file-contract")) return false;
    if (std.mem.eql(u8, args[2], "send")) {
        if (args.len != 5) return error.BadOpenFileChildArgs;
        const hwnd = try std.fmt.parseInt(usize, args[3], 16);
        try Window.sendOpenFile(@ptrFromInt(hwnd), args[4], 3000);
    } else if (std.mem.eql(u8, args[2], "startup")) {
        var win = try Window.init(64, 64, "Zenit open file startup contract");
        defer win.deinit();
        try Window.initAppWithDelegateChecked(); // No duplicate delivery on reinitialization.
        try take(&win, first);
        try take(&win, second);
        try empty(&win);
    } else return error.BadOpenFileChildArgs;
    return true;
}
fn child(io: std.Io, extra: []const []const u8) !void {
    const allocator = std.heap.page_allocator;
    const exe = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe);
    var argv = try allocator.alloc([]const u8, extra.len + 2);
    defer allocator.free(argv);
    argv[0] = exe;
    argv[1] = "--zenit-open-file-contract";
    @memcpy(argv[2..], extra);
    var process = try std.process.spawn(io, .{ .argv = argv, .create_no_window = true, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit });
    var reaped = false;
    defer if (!reaped) {
        process.kill(io);
    };
    var timer = try @import("zenit_time").Timer.start(io);
    while (true) {
        const state = WaitForSingleObject(process.id.?, 0);
        if (state == 0) break;
        if (state != 258) return error.OpenFileChildWaitFailed;
        if (timer.read() > 5 * std.time.ns_per_s) return error.OpenFileChildTimeout;
        Window.pumpAppEventsTimeout(1); // Required for cross-process SendMessage delivery.
    }
    const term = try process.wait(io);
    reaped = true;
    try require(term == .exited and term.exited == 0);
}
pub fn run(app: *App) !void {
    const win = &app.win;
    const foreground = GetForegroundWindow();
    const count = Window.liveWindowCount();
    const hwnd = win.getNativeSurfaceHandle();
    try empty(win);
    try parse("zenit.exe --other ordinary.md --zenit-open-file \"C:\\Zenit fixture\\字体 🧪.md\" --zenit-open-file=\"C:\\Zenit fixture\\second.md\"", true);
    try take(win, first);
    try take(win, second);
    try empty(win);
    try parse("zenit.exe --zenit-open-file C:\\valid.md --zenit-open-file", false);
    try parse("zenit.exe --zenit-open-file C:\\valid.md --zenit-open-file=", false);
    try empty(win); // Failed batches cannot leave a partially delivered first path.
    var source: [first.len:0]u8 = first[0..first.len].*;
    try Window.sendOpenFile(hwnd, &source, 1000);
    @memset(&source, 'x'); // Receiver must own the data after SendMessage returns.
    try take(win, first);
    const cwd = try std.process.currentPathAlloc(app.cx.io, std.heap.page_allocator);
    defer std.heap.page_allocator.free(cwd);
    const relative_expected = try std.fs.path.join(std.heap.page_allocator, &.{ cwd, "relative.md" });
    defer std.heap.page_allocator.free(relative_expected);
    try Window.sendOpenFile(hwnd, "folder\\..\\relative.md", 1000);
    try take(win, relative_expected);
    const invalid = [_]u8{ 'C', ':', '\\', 0xff, 0 };
    const embedded = [_]u8{ 'C', ':', '\\', 0, 'x', 0 };
    try require(zenit_win_open_path_contract_raw(hwnd, tag + 1, first.ptr, first.len + 1) == 0);
    try require(zenit_win_open_path_contract_raw(hwnd, tag, first.ptr, first.len) == 0);
    try require(zenit_win_open_path_contract_raw(hwnd, tag, &invalid, invalid.len) == 0);
    try require(zenit_win_open_path_contract_raw(hwnd, tag, &embedded, embedded.len) == 0);
    try require(zenit_win_open_path_contract_raw(hwnd, tag, "relative.md", 12) == 0);
    try require(zenit_win_open_path_contract_raw(hwnd, tag, null, 0) == 0);
    try empty(win);
    // A second Window consumes the same process FIFO rather than losing paths.
    {
        var other = try Window.init(64, 64, "Zenit open file queue consumer");
        defer other.deinit();
        try Window.sendOpenFile(hwnd, first, 1000);
        try take(&other, first);
        _ = zenit_win_open_path_contract_close(other.getNativeSurfaceHandle());
        if (Window.sendOpenFile(other.getNativeSurfaceHandle(), first, 1000)) |_| return error.ClosingWindowAccepted else |err| {
            try require(err == error.OpenFileDeliveryFailed);
        }
    }
    for (0..256) |_| try Window.sendOpenFile(hwnd, second, 1000);
    if (Window.sendOpenFile(hwnd, first, 1000)) |_| return error.OpenFileQuotaNotEnforced else |err| {
        try require(err == error.OpenFileDeliveryFailed);
    }
    for (0..256) |_| try take(win, second);
    try empty(win);
    // Exercise paths beyond MAX_PATH and the byte quota independently of count.
    const long = try std.heap.page_allocator.allocSentinel(u8, 3 + 5000 * 7, 0);
    defer std.heap.page_allocator.free(long);
    @memcpy(long[0..3], "C:\\");
    for (0..5000) |index| @memcpy(long[3 + index * 7 ..][0..7], "目录\\");
    const byte_capacity = (4 * 1024 * 1024) / (long.len + 1);
    for (0..byte_capacity) |_| try Window.sendOpenFile(hwnd, long, 1000);
    if (Window.sendOpenFile(hwnd, long, 1000)) |_| return error.OpenFileByteQuotaNotEnforced else |err| {
        try require(err == error.OpenFileDeliveryFailed);
    }
    for (0..byte_capacity) |_| try take(win, long);
    try empty(win);
    std.log.info("Windows open-file bounds: path_bytes={d}, byte_quota_entries={d}, count_quota_entries=256 PASS", .{ long.len, byte_capacity });
    try child(app.cx.io, &.{ "startup", "ordinary.md", "--application-flag", "--zenit-open-file", first, "--zenit-open-file=C:\\Zenit fixture\\second.md" });
    const handle = try std.fmt.allocPrint(std.heap.page_allocator, "{x}", .{@intFromPtr(hwnd)});
    defer std.heap.page_allocator.free(handle);
    try child(app.cx.io, &.{ "send", handle, first });
    try take(win, first);
    try empty(win);
    try require(Window.liveWindowCount() == count and GetForegroundWindow() == foreground);
    std.log.info("Windows open files: real argv and cross-process WM_COPYDATA, Unicode FIFO, exact retry, ownership, global queue, rejection and quota PASS", .{});
}
