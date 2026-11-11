//! AppKit panels scoped to their originating window. Poll on the UI thread
//! and keep each pending handle in the host that owns the resulting action.
const ui = @import("ui");

const Native = opaque {};
extern fn zw_file_sheet_begin(u32, c_int, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8) ?*Native;
extern fn zw_file_sheet_count(*Native) isize;
extern fn zw_file_sheet_path(*Native, usize, [*]u8, usize) isize;
extern fn zw_file_sheet_destroy(*Native) void;

pub const Kind = enum(c_int) { file, folder, file_or_folder, multiple_files, save };
pub const Options = struct {
    kind: Kind,
    title: ?[*:0]const u8 = null,
    prompt: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    initial: ?[]const u8 = null,
};

pub const Sheet = struct {
    native: *Native,

    pub fn begin(cx: *const ui.Cx, options: Options) !Sheet {
        const initial = if (options.initial) |value| try cx.allocator.dupeSentinel(u8, value, 0) else null;
        defer if (initial) |value| cx.allocator.free(value);
        return .{ .native = zw_file_sheet_begin(cx.native_window_id, @backingInt(options.kind), options.title, options.prompt, options.message, if (initial) |value| value.ptr else null) orelse return error.FileSheetUnavailable };
    }

    /// null means open, zero means cancelled, positive means selected paths.
    pub fn count(self: Sheet) ?usize {
        const length = zw_file_sheet_count(self.native);
        return if (length < 0) null else @intCast(length);
    }

    pub fn path(self: Sheet, index: usize, buffer: []u8) ![]const u8 {
        const length = zw_file_sheet_path(self.native, index, buffer.ptr, buffer.len);
        if (length < 0) return error.InvalidSelectedPath;
        return buffer[0..@intCast(length)];
    }

    pub fn deinit(self: Sheet) void {
        zw_file_sheet_destroy(self.native);
    }
};
