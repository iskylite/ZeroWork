//! DevTools "goto source": resolve a node's `component_name` to a source
//! location and open it in an external editor.
//!
//! The name->location table is produced offline by `tools/gen_component_index.zig`
//! (AST scan of `component_name = "..."` assignments); see that file for why the
//! locations are scanned rather than captured with `@src()`.
//!
//! Two tables are consulted: zenit's own (compiled in) and, optionally, one
//! registered by the host app for its components. Paths in both are relative to
//! their respective source roots, which the app supplies at runtime via
//! `configure`, a built binary has no idea where its sources live.
const std = @import("std");
const builtin = @import("builtin");

const framework_index = @import("../component_index_generated.zig");

pub const Entry = framework_index.Entry;

/// A generated index plus the absolute path its entries are relative to.
pub const IndexSource = struct {
    entries: []const Entry,
    /// Absolute path of the source root; entry `file`s are joined onto it.
    root: []const u8,
};

pub const Resolved = struct {
    /// Absolute path on disk.
    file: []const u8,
    line: u32,
    col: u32,
    label: []const u8,
};

/// Editor launch command. `{file}`, `{line}`, `{col}` are substituted.
pub const EditorCommand = []const []const u8;

/// VS Code / Cursor style: `code --goto path:line:col`.
pub const default_editor: EditorCommand = &.{ "code", "--goto", "{file}:{line}:{col}" };

var g_framework_root: ?[]const u8 = null;
var g_app: ?IndexSource = null;
var g_editor: EditorCommand = default_editor;

/// Point the resolver at on-disk sources. Call once at startup from an app that
/// wants goto-source; without it nothing resolves and DevTools shows no button.
///
/// `framework_root` is the absolute path of the zenit checkout (entries are
/// relative to it); pass null if zenit's sources are not available locally.
/// `app` is the host app's generated index, if it has one.
pub fn configure(opts: struct {
    framework_root: ?[]const u8 = null,
    app: ?IndexSource = null,
    editor: ?EditorCommand = null,
}) void {
    g_framework_root = opts.framework_root;
    g_app = opts.app;
    if (opts.editor) |e| g_editor = e;

    // findIn is binary search; if the app's supplied index is not sorted by name, it silently
    // MISSes (final eql check prevents mismatches, but lookup failure = goto button never shows,
    // extremely hard to debug). In Debug builds, enforce the contract at configure time.
    if (builtin.mode == .debug) {
        if (opts.app) |app| {
            var i: usize = 1;
            while (i < app.entries.len) : (i += 1) {
                std.debug.assert(!std.mem.lessThan(u8, app.entries[i].name, app.entries[i - 1].name));
            }
        }
    }
}

/// True if any index is usable, DevTools uses this to decide whether to render
/// the goto affordance at all.
pub fn isConfigured() bool {
    return g_framework_root != null or g_app != null;
}

/// Runtime-address goto-source requires executable debug info. This is a cheap
/// render-time gate; the actual DWARF lookup still happens lazily on click.
pub fn addressResolutionAvailable() bool {
    return !builtin.strip_debug_info;
}

/// Look up `name`, preferring the app's own components over the framework's:
/// when an app names a component the same as a built-in, the app's is what the
/// developer means.
///
/// Returns a location whose `file` is owned by the caller.
pub fn resolve(alloc: std.mem.Allocator, name: []const u8) !?Resolved {
    if (g_app) |app| {
        if (findIn(app.entries, name)) |e| return try join(alloc, app.root, e);
    }
    if (g_framework_root) |root| {
        if (findIn(&framework_index.entries, name)) |e| return try join(alloc, root, e);
    }
    return null;
}

/// Whether `name` resolves, without allocating. Used to decide if the
/// goto affordance is worth rendering at all.
pub fn has(name: []const u8) bool {
    if (g_app) |app| {
        if (findIn(app.entries, name) != null) return true;
    }
    if (g_framework_root != null) {
        if (findIn(&framework_index.entries, name) != null) return true;
    }
    return false;
}

/// Resolve runtime code address to source location. styled sources pass function entry address;
/// inline builder / setStyle pass return address, the latter minus 1 before lookup to avoid DWARF
/// attributing it to the statement after the call.
///
/// Resolution only happens when user clicks DevTools `->`. Does not enter render/style-write hot
/// path. Returns null if Release strips debug info, dSYM unavailable, or address from external
/// dynamic library.
pub fn resolveAddress(alloc: std.mem.Allocator, io: std.Io, address: usize, is_return_address: bool) !?Resolved {
    if (builtin.strip_debug_info or address == 0) return null;
    const lookup_address = if (is_return_address and address > 0) address - 1 else address;
    const debug_info = std.debug.getSelfDebugInfo() catch return null;
    // Symbol lookup holds the debug-info lock. A tracing allocator would re-enter
    // that lock while capturing allocation stacks; keep scratch storage untraced.
    var text_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer text_arena.deinit();
    var symbols: std.ArrayList(std.debug.Symbol) = .empty;
    defer symbols.deinit(std.heap.page_allocator);
    debug_info.getSymbols(io, std.heap.page_allocator, text_arena.allocator(), lookup_address, false, &symbols) catch return null;
    const sl = for (symbols.items) |symbol| {
        if (symbol.source_location) |location| break location;
    } else return null;

    const file = try normalizeDebugPath(alloc, io, sl.file_name);
    return .{
        .file = file,
        .line = std.math.cast(u32, sl.line) orelse std.math.maxInt(u32),
        .col = std.math.cast(u32, sl.column) orelse 1,
        .label = "debug-info",
    };
}

fn normalizeDebugPath(alloc: std.mem.Allocator, io: std.Io, raw: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(raw)) return std.fs.path.resolveAlloc(alloc, &.{raw});

    // `zig build` often writes relative source paths into DWARF. Respect process cwd first
    // (command-line run), then try configured source root for host app and zenit (Finder launch cwd
    // is often /).
    if (pathExists(io, raw)) return std.fs.path.resolveAlloc(alloc, &.{raw});
    if (g_app) |app| {
        const candidate = try std.fs.path.join(alloc, &.{ app.root, raw });
        if (pathExists(io, candidate)) return candidate;
        alloc.free(candidate);
    }
    if (g_framework_root) |root| {
        const candidate = try std.fs.path.join(alloc, &.{ root, raw });
        if (pathExists(io, candidate)) return candidate;
        alloc.free(candidate);
    }

    // Keep a diagnostic fallback; editor will handle it relative to its own cwd.
    return alloc.dupe(u8, raw);
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn join(alloc: std.mem.Allocator, root: []const u8, e: Entry) !Resolved {
    const raw = try std.fs.path.join(alloc, &.{ root, e.file });
    // A build-time root can be relative-ish ("…/app/../zenit/./src"),
    // which works but is what the user sees in their editor's title bar.
    const resolved = std.fs.path.resolveAlloc(alloc, &.{raw}) catch return .{
        .file = raw,
        .line = e.line,
        .col = e.col,
        .label = e.label,
    };
    alloc.free(raw);
    return .{
        .file = resolved,
        .line = e.line,
        .col = e.col,
        .label = e.label,
    };
}

/// Binary search over a name-sorted index.
fn findIn(entries: []const Entry, name: []const u8) ?Entry {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.lessThan(u8, entries[mid].name, name)) lo = mid + 1 else hi = mid;
    }
    if (lo < entries.len and std.mem.eql(u8, entries[lo].name, name)) return entries[lo];
    return null;
}

/// Launch the configured editor on `loc`.
///
/// The launcher is *not* waited on: `code --goto` is a Node.js wrapper that
/// takes ~1.1s even when VS Code is already running, and this is called from a
/// click handler on the UI thread. Instead we double-fork, the intermediate
/// child is reaped immediately and the grandchild that execs the editor is
/// re-parented to init, so it neither blocks us nor lingers as a zombie.
pub fn open(alloc: std.mem.Allocator, io: std.Io, loc: Resolved) !void {
    // WARNING: fork discipline. Multi-threaded GUI process (CVDisplayLink/render thread resident).
    // Forked child can only call async-signal-safe functions; any heap allocation may deadlock on
    // malloc lock held by another thread at fork moment, touching ObjC/CF aborts directly
    // (objc_initializeAfterForkError). So argv expansion and C string conversion all complete
    // before fork, grandchild only does setsid + execvpe.
    var argv = @as(std.ArrayList([]const u8), .empty);
    defer {
        for (argv.items) |a| alloc.free(a);
        argv.deinit(alloc);
    }
    for (g_editor) |part| {
        try argv.ensureUnusedCapacity(alloc, 1);
        argv.appendAssumeCapacity(try expand(alloc, part, loc));
    }
    if (argv.items.len == 0) return error.EmptyEditorCommand;

    if (comptime @import("builtin").os.tag == .windows) {
        const child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        // Windows process lifetime is independent of these launcher handles.
        std.os.windows.CloseHandle(child.thread_handle);
        std.os.windows.CloseHandle(child.id.?);
        return;
    }

    var argv_z_owned = @as(std.ArrayList([:0]const u8), .empty);
    defer {
        for (argv_z_owned.items) |s| alloc.free(s);
        argv_z_owned.deinit(alloc);
    }
    const argv_z = try alloc.allocSentinel(?[*:0]const u8, argv.items.len, null);
    defer alloc.free(argv_z);
    for (argv.items, 0..) |a, i| {
        try argv_z_owned.ensureUnusedCapacity(alloc, 1);
        const z = try alloc.dupeSentinel(u8, a, 0);
        argv_z_owned.appendAssumeCapacity(z);
        argv_z[i] = z.ptr;
    }
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    // Resolve PATH candidates before fork. The forked child only makes native
    // async-signal-safe calls, and never allocates or enters the Io runtime.
    var candidates: std.ArrayList([:0]const u8) = .empty;
    defer {
        for (candidates.items) |path| alloc.free(path);
        candidates.deinit(alloc);
    }
    if (std.mem.indexOfScalar(u8, argv.items[0], '/') != null) {
        try candidates.ensureUnusedCapacity(alloc, 1);
        candidates.appendAssumeCapacity(try alloc.dupeSentinel(u8, argv.items[0], 0));
    } else {
        const path = @import("zenit_environment").getBorrowed("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
        var directories = std.mem.splitScalar(u8, path, ':');
        while (directories.next()) |directory| {
            const candidate = try std.fs.path.join(alloc, &.{ if (directory.len == 0) "." else directory, argv.items[0] });
            defer alloc.free(candidate);
            try candidates.ensureUnusedCapacity(alloc, 1);
            candidates.appendAssumeCapacity(try alloc.dupeSentinel(u8, candidate, 0));
        }
    }

    // Double-fork: middle child exits immediately (waitpid below returns at once), exec'd editor
    // grandchild adopted by init, neither blocking UI thread nor leaving zombies.
    const pid = fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const inner = fork();
        if (inner < 0) std.c._exit(1);
        if (inner == 0) {
            // Detach from GUI process session/process group; editor launcher's fate independent of
            // app.
            _ = setsid();
            for (candidates.items) |candidate| _ = execve(candidate.ptr, argv_z.ptr, envp);
            std.c._exit(1);
        }
        // _exit not exit: libc exit runs atexit/flush stdio, not async-signal-safe in forked child
        // either.
        std.c._exit(0);
    }
    while (true) {
        const waited = std.c.waitpid(pid, null, 0);
        if (waited == pid) break;
        if (std.posix.errno(waited) != .INTR) return error.WaitFailed;
    }
}

fn expand(alloc: std.mem.Allocator, template: []const u8, loc: Resolved) ![]const u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    var rest = template;
    while (rest.len > 0) {
        const open_i = std.mem.indexOfScalar(u8, rest, '{') orelse {
            try out.writer.writeAll(rest);
            break;
        };
        try out.writer.writeAll(rest[0..open_i]);
        const close_i = std.mem.indexOfScalarPos(u8, rest, open_i, '}') orelse {
            try out.writer.writeAll(rest[open_i..]);
            break;
        };
        const key = rest[open_i + 1 .. close_i];
        if (std.mem.eql(u8, key, "file")) {
            try out.writer.writeAll(loc.file);
        } else if (std.mem.eql(u8, key, "line")) {
            try out.writer.print("{d}", .{loc.line});
        } else if (std.mem.eql(u8, key, "col")) {
            try out.writer.print("{d}", .{loc.col});
        } else {
            // Unknown placeholder: emit verbatim so a literal brace survives.
            try out.writer.writeAll(rest[open_i .. close_i + 1]);
        }
        rest = rest[close_i + 1 ..];
    }
    return out.toOwnedSlice();
}

test "expand substitutes placeholders" {
    const loc: Resolved = .{ .file = "/a/b.zig", .line = 42, .col = 7, .label = "app" };
    const got = try expand(std.testing.allocator, "{file}:{line}:{col}", loc);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/a/b.zig:42:7", got);
}

test "expand leaves unknown placeholders alone" {
    const loc: Resolved = .{ .file = "/a/b.zig", .line = 1, .col = 1, .label = "app" };
    const got = try expand(std.testing.allocator, "x{nope}y{line}", loc);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("x{nope}y1", got);
}

noinline fn sourceAddressProbe() void {}

test "resolveAddress symbolizes a styled function entry" {
    if (!addressResolutionAvailable()) return;
    const loc = try resolveAddress(std.testing.allocator, std.testing.io, @intFromPtr(&sourceAddressProbe), false);
    const resolved = loc orelse return error.MissingDebugInfo;
    defer std.testing.allocator.free(resolved.file);
    try std.testing.expectEqualStrings("source_link.zig", std.fs.path.basename(resolved.file));
    try std.testing.expect(resolved.line > 0);
}

test "findIn locates entries and rejects misses" {
    const entries = [_]Entry{
        .{ .name = "Alpha", .file = "a.zig", .line = 1, .col = 1, .label = "t" },
        .{ .name = "Beta", .file = "b.zig", .line = 2, .col = 1, .label = "t" },
        .{ .name = "Gamma", .file = "c.zig", .line = 3, .col = 1, .label = "t" },
    };
    try std.testing.expectEqual(@as(u32, 2), findIn(&entries, "Beta").?.line);
    try std.testing.expectEqual(@as(u32, 1), findIn(&entries, "Alpha").?.line);
    try std.testing.expectEqual(@as(u32, 3), findIn(&entries, "Gamma").?.line);
    try std.testing.expect(findIn(&entries, "Delta") == null);
    try std.testing.expect(findIn(&entries, "Zzz") == null);
    try std.testing.expect(findIn(&.{}, "Alpha") == null);
}

test "framework index is sorted so binary search is valid" {
    for (framework_index.entries[1..], 0..) |e, i| {
        try std.testing.expect(!std.mem.lessThan(u8, e.name, framework_index.entries[i].name));
    }
}

// Native POSIX calls: no allocator, runtime locks or Objective-C work after fork.
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
