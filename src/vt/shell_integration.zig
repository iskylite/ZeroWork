//! Session-only shell integration. The returned input is evaluated once in the
//! original interactive shell; it neither uploads files nor replaces the shell.
//! Only a freshly owned startup input window may inject this automatically.
//! An arbitrary existing foreground program is never a safe initialization point.
const std = @import("std");
pub const bash = @embedFile("shell/integration.bash");
pub const zsh = @embedFile("shell/integration.zsh");
pub const fragment_bytes = 128;
/// Logical payload per receipt. Encoded bytes and the bounded reader prelude
/// fit the 16 KiB transport budget; physical lines stay below PTY limits.
pub const initialization_batch_bytes = 8 * 1024;
pub const receiver = @embedFile("shell/receive.sh");
pub const fast_receiver = @embedFile("shell/receive_fast.sh");

/// The first command must run before it can disable remote echo. Hold only
/// that startup window, then remove complete copies of our known command.
/// Everything else, including prompts and unrelated output, stays byte exact.
/// A missing receipt or an oversized window is deliberately passed through.
pub const EchoFilter = struct {
    pub const capacity = 16 * 1024;
    header: []const u8 = "",
    receipt: [96]u8 = undefined,
    receipt_len: usize = 0,
    buffer: [capacity]u8 = undefined,
    len: usize = 0,
    active: bool = false,

    pub const Ready = struct { bytes: []const u8, remainder: []const u8 = "" };

    pub fn arm(self: *EchoFilter, header: []const u8, nonce: []const u8) void {
        self.header = std.mem.trimEnd(u8, header, "\n");
        const receipt = std.fmt.bufPrint(&self.receipt, "\x1b]133;P;zw_init={s};1;128\x07", .{nonce}) catch return;
        self.receipt_len = receipt.len;
        self.len = 0;
        self.active = true;
    }

    pub fn feed(self: *EchoFilter, bytes: []const u8) ?Ready {
        if (!self.active) return .{ .bytes = bytes };
        if (bytes.len > self.buffer.len - self.len) {
            self.active = false;
            return .{ .bytes = self.buffer[0..self.len], .remainder = bytes };
        }
        @memcpy(self.buffer[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        const receipt_start = std.mem.indexOf(u8, self.buffer[0..self.len], self.receipt[0..self.receipt_len]) orelse return null;
        self.active = false;
        var read: usize = 0;
        var write: usize = 0;
        while (read < receipt_start) {
            if (echoEnd(self.buffer[read..receipt_start], self.header)) |count| {
                read += count;
            } else {
                self.buffer[write] = self.buffer[read];
                write += 1;
                read += 1;
            }
        }
        std.mem.copyForwards(u8, self.buffer[write..], self.buffer[receipt_start..self.len]);
        write += self.len - receipt_start;
        self.len = write;
        return .{ .bytes = self.buffer[0..write] };
    }

    pub fn finish(self: *EchoFilter) []const u8 {
        if (!self.active) return "";
        self.active = false;
        return self.buffer[0..self.len];
    }

    // Readline and ZLE add wrapping spaces/CR/erase-line and may redraw one
    // character after CR or backspace. Ignore only those presentation bytes;
    // every source character (including spaces and the nonce) must match.
    // A mismatch leaves the entire candidate untouched.
    fn echoEnd(bytes: []const u8, header: []const u8) ?usize {
        if (bytes.len == 0 or header.len == 0 or bytes[0] != header[0]) return null;
        var source: usize = 0;
        var index: usize = 0;
        var after_cr = false;
        while (index < bytes.len) {
            if (source == header.len and echoTerminator(bytes[index..])) return index;
            const byte = bytes[index];
            if (byte == ' ' and index + 2 < bytes.len and bytes[index + 1] == '\r' and bytes[index + 2] != '\n') {
                // Readline's padding space is followed by CR, with no
                // source character redrawn at the start of the next row.
                index += 2;
                continue;
            }
            if (byte == '\r') {
                if (index + 1 == bytes.len or bytes[index + 1] == '\n') return null;
                var next = index + 1;
                if (std.mem.startsWith(u8, bytes[next..], "\x1b[K")) next += 3;
                // ZLE previews the next wrap character, returns to column 0,
                // then writes it again. Recognize that redraw before matching
                // source characters, including adjacent equal chars such as ||.
                if (next + 2 < bytes.len and bytes[next + 1] == '\r' and bytes[next] == bytes[next + 2]) {
                    index = next + 2;
                    continue;
                }
                // Bash Readline can print the first wrap character, CR,
                // then print it again. Consume that redraw before matching
                // the next source character: it may be identical (||, ((,
                // or repeated nonce digits), so mismatch recovery is too late.
                if (source != 0 and index != 0 and bytes[index - 1] == header[source - 1] and next < bytes.len and bytes[next] == header[source - 1]) {
                    index = next + 1;
                    continue;
                }
                after_cr = true;
                index += 1;
                continue;
            }
            if (byte == '\x08' and source != 0) {
                source -= 1;
                index += 1;
                continue;
            }
            if (byte == '\x1b' and index + 2 < bytes.len and bytes[index + 1] == '[') {
                var end = index + 2;
                while (end < bytes.len and (std.ascii.isDigit(bytes[end]) or bytes[end] == ';' or bytes[end] == '?')) : (end += 1) {}
                if (end == bytes.len) return null;
                if (bytes[end] != 'K' and bytes[end] != 'm' and !std.mem.eql(u8, bytes[index .. end + 1], "\x1b[?2004l")) return null;
                index = end + 1;
                continue;
            }
            if (source == header.len) return null;
            if (byte != header[source]) {
                if (!after_cr or source == 0 or byte != header[source - 1]) return null;
                after_cr = false;
                index += 1;
                continue;
            }
            source += 1;
            index += 1;
            after_cr = false;
        }
        return null;
    }

    fn echoTerminator(bytes: []const u8) bool {
        var index: usize = 0;
        while (index < bytes.len) {
            switch (bytes[index]) {
                ' ', '\r' => index += 1,
                '\n' => return true,
                '\x1b' => {
                    const tail = bytes[index..];
                    const count: usize = if (std.mem.startsWith(u8, tail, "\x1b[?2004l")) 8 else if (std.mem.startsWith(u8, tail, "\x1b[0m")) 4 else return false;
                    index += count;
                },
                else => return false,
            }
        }
        return false;
    }
};

/// Startup transport: one bootstrap line starts a temporary silent receiver.
/// Each following batch of short lines is sent only after the caller receives
/// its matching nonce/sequence/size ACK. ACK is flow
/// control, not command completion or authentication. Only the final eval
/// installs hooks; A/B after that command establish shell-reported readiness.
/// Free every returned line, then the outer slice.
pub fn initializerChunks(allocator: std.mem.Allocator, nonce: []const u8) ![][]u8 {
    return contextInitializerChunks(allocator, nonce);
}
pub fn contextInitializerChunks(allocator: std.mem.Allocator, nonce: []const u8) ![][]u8 {
    if (nonce.len == 0 or nonce.len > 32) return error.InvalidNonce;
    for (nonce) |byte| if (!std.ascii.isHex(byte)) return error.InvalidNonce;
    const hooks = try initializer(allocator);
    defer allocator.free(hooks);
    const script = try std.fmt.allocPrint(allocator, "__zw_attach_id='{s}';{s}", .{ nonce, hooks });
    defer allocator.free(script);
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    // Bootstrap is one bounded command; its exact echo is removed by EchoFilter.
    // Subsequent fragments are consumed by the receiver, never by readline/ZLE.
    // ACK is emitted after stty -echo.
    var first: std.ArrayList(u8) = .empty;
    errdefer first.deinit(allocator);
    var source_lines = std.mem.splitScalar(u8, receiver, '\n');
    while (source_lines.next()) |source_line| {
        const line = std.mem.trim(u8, source_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try first.appendSlice(allocator, line);
        if (line[line.len - 1] != ';') try first.append(allocator, ' ');
    }
    try first.appendSlice(allocator, "_zwA=");
    try appendAck(&first, allocator, nonce, 1, fragment_bytes);
    try first.appendSlice(allocator, ";_zwR ${BASH_VERSION:+-n}${ZSH_VERSION:+-k} ");
    try appendAnsiQuoted(&first, allocator, nonce);
    try first.appendSlice(allocator, "||_zwD=0;builtin unset -f _zwR _zwG;[[ ${_zwD-} = 1 ]]&&{ builtin eval \"$_zwP\";builtin printf %s \"$_zwA\";};builtin unset _zwT _zwI _zwA _zwL _zwC _zwP _zwD _zwF\n");
    const header = try first.toOwnedSlice(allocator);
    lines.append(allocator, header) catch |err| {
        allocator.free(header);
        return err;
    };
    var offset: usize = 0;
    while (offset < script.len) {
        const batch_end = @min(script.len, offset + initialization_batch_bytes);
        const batch_size = batch_end - offset;
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        // Upgrade only after the startup ACK disabled echo and canonical input.
        // The transport prelude stays in this batch; it needs no extra RTT.
        if (offset == 0) try appendReceiverUpgrade(&line, allocator);
        while (offset < batch_end) {
            const fragment = script[offset..@min(batch_end, offset + fragment_bytes)];
            // The receiver emits nothing between lines; acknowledge only once
            // all fragments in this batch have been read and appended.
            try line.appendSlice(allocator, "_zwA=;");
            try line.appendSlice(allocator, if (offset == 0) "_zwP=" else "_zwP+=");
            try appendAnsiQuoted(&line, allocator, fragment);
            offset += fragment.len;
            if (offset == batch_end) {
                try line.appendSlice(allocator, "; _zwA=");
                try appendAck(&line, allocator, nonce, lines.items.len + 1, batch_size);
            }
            try line.append(allocator, '\n');
        }
        const owned = try line.toOwnedSlice(allocator);
        lines.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    var final: std.ArrayList(u8) = .empty;
    errdefer final.deinit(allocator);
    try final.appendSlice(allocator, "_zwD=1; _zwA=");
    try appendAck(&final, allocator, nonce, lines.items.len + 1, 0);
    try final.append(allocator, '\n');
    const last = try final.toOwnedSlice(allocator);
    lines.append(allocator, last) catch |err| {
        allocator.free(last);
        return err;
    };
    return lines.toOwnedSlice(allocator);
}

/// One shell command with short physical lines, including its final LF. Keep
/// newlines inside the quoted eval argument: a large single physical line can
/// exceed the PTY canonical limit before readline/ZLE enters raw input mode.
/// Direct-eval callers may see script/continuation-prompt echo. Production SSH
/// uses initializerChunks' silent receiver and filters only matching bootstrap
/// echo with EchoFilter; this builder provides no general shell-history or
/// unknown-output suppression.
pub fn initializer(allocator: std.mem.Allocator) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "if test -n \"${TMUX-}${STY-}\"; then builtin printf '\\e]133;P;zw_reject=%s;reason=UnsupportedMultiplexer\\a' \"${__zw_attach_id-}\"; elif test -n \"${BASH_VERSION-}\"; then builtin eval ");
    try appendQuoted(&output, allocator, bash);
    try output.appendSlice(allocator, "; elif test -n \"${ZSH_VERSION-}\"; then builtin eval ");
    try appendQuoted(&output, allocator, zsh);
    try output.appendSlice(allocator, "; else printf '\\033]133;P;zw_reject=%s;reason=UnsupportedShell\\007' \"${__zw_attach_id-}\"; fi\n");
    return output.toOwnedSlice(allocator);
}

fn appendReceiverUpgrade(output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    var compact: std.ArrayList(u8) = .empty;
    defer compact.deinit(allocator);
    var source = std.mem.splitScalar(u8, fast_receiver, '\n');
    while (source.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try compact.appendSlice(allocator, line);
        if (line[line.len - 1] != ';') try compact.append(allocator, ' ');
    }
    var offset: usize = 0;
    while (offset < compact.items.len) {
        const end = @min(compact.items.len, offset + fragment_bytes);
        try output.appendSlice(allocator, if (offset == 0) "_zwA=;_zwF=" else "_zwF+=");
        try appendAnsiQuoted(output, allocator, compact.items[offset..end]);
        try output.append(allocator, '\n');
        offset = end;
    }
    try output.appendSlice(allocator, "if test -n \"${ZSH_VERSION-}\";then builtin zmodload -e zsh/system 2>/dev/null||{ builtin zmodload zsh/system 2>/dev/null&&_zwI='builtin zmodload -u zsh/system||_zwD=0;'$_zwI;};fi\n" ++
        "_zwB=;_zwI='builtin unset _zwB;'$_zwI\n" ++
        "if test -n \"${BASH_VERSION-}\"||test \"$(builtin whence -w sysread)\" = 'sysread: builtin';then builtin eval \"$_zwF\";fi\n" ++
        "builtin unset _zwF\n");
}

fn appendAck(output: *std.ArrayList(u8), allocator: std.mem.Allocator, nonce: []const u8, sequence: usize, size: usize) !void {
    const value = try std.fmt.allocPrint(allocator, "$'\\e]133;P;zw_init={s};{d};{d}\\a'", .{ nonce, sequence, size });
    defer allocator.free(value);
    try output.appendSlice(allocator, value);
}

fn appendQuoted(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try output.append(allocator, '\'');
    for (value) |byte| switch (byte) {
        '\'' => try output.appendSlice(allocator, "'\\''"),
        else => try output.append(allocator, byte),
    };
    try output.append(allocator, '\'');
}

fn appendAnsiQuoted(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try output.appendSlice(allocator, "$'");
    for (value) |byte| switch (byte) {
        '\\' => try output.appendSlice(allocator, "\\\\"),
        '\'' => try output.appendSlice(allocator, "\\'"),
        '\n' => try output.appendSlice(allocator, "\\n"),
        '\r' => try output.appendSlice(allocator, "\\r"),
        '\t' => try output.appendSlice(allocator, "\\t"),
        else => try output.append(allocator, byte),
    };
    try output.append(allocator, '\'');
}

test "initializer uses bounded physical lines without terminal control bytes" {
    const input = try initializer(std.testing.allocator);
    defer std.testing.allocator.free(input);
    try std.testing.expect(input.len < 8 * 1024);
    try std.testing.expectEqual(@as(u8, '\n'), input[input.len - 1]);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(line.len < 512);
        for (line) |byte| try std.testing.expect(byte >= 32 and byte != 127);
    }
}

test "initialization chunks are bounded lines with nonce sequence and size" {
    const nonce = "0123456789abcdef0123456789abcdef";
    const chunks = try initializerChunks(std.testing.allocator, nonce);
    defer {
        for (chunks) |chunk| std.testing.allocator.free(chunk);
        std.testing.allocator.free(chunks);
    }
    // Current hooks fit one 8 KiB batch: bootstrap, payload, final receipt.
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    for (chunks, 0..) |chunk, index| {
        try std.testing.expect(chunk.len < 16 * 1024);
        const physical_lines = std.mem.count(u8, chunk, "\n");
        try std.testing.expect(physical_lines > 0 and physical_lines <= initialization_batch_bytes / fragment_bytes + 16);
        var physical = std.mem.splitScalar(u8, chunk[0 .. chunk.len - 1], '\n');
        while (physical.next()) |line| {
            try std.testing.expect(line.len < if (index == 0) @as(usize, 1024) else 512);
            for (line) |byte| try std.testing.expect(byte >= 32 and byte != 127);
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, chunk, "zw_init="));
        try std.testing.expect(std.mem.indexOf(u8, chunk, nonce) != null);
    }
    try std.testing.expectError(error.InvalidNonce, initializerChunks(std.testing.allocator, "x'; touch bad"));
    const long_nonce: [33]u8 = @splat('a');
    try std.testing.expectError(error.InvalidNonce, initializerChunks(std.testing.allocator, &long_nonce));
}

test "initializer echo filter preserves banners prompts and all read boundaries" {
    const header = "_zwR() { _zwP='0123'; }; _zwR\n";
    const ack = "\x1b]133;P;zw_init=0123;1;128\x07";
    const plain = "banner\r\nroot# " ++ header[0 .. header.len - 1] ++ "\r\nlate banner\r\nroot# " ++ header[0 .. header.len - 1] ++ "\r\n" ++ ack ++ "after\r\n";
    const expected = "banner\r\nroot# \r\nlate banner\r\nroot# \r\n" ++ ack ++ "after\r\n";
    for (0..plain.len + 1) |split| {
        var filter: EchoFilter = .{};
        filter.arm(header, "0123");
        var actual: std.ArrayList(u8) = .empty;
        defer actual.deinit(std.testing.allocator);
        for ([_][]const u8{ plain[0..split], plain[split..] }) |part| {
            if (filter.feed(part)) |ready| {
                try actual.appendSlice(std.testing.allocator, ready.bytes);
                try actual.appendSlice(std.testing.allocator, ready.remainder);
            }
        }
        try std.testing.expectEqualStrings(expected, actual.items);
    }
    var filter: EchoFilter = .{};
    filter.arm(header, "0123");
    var single: std.ArrayList(u8) = .empty;
    defer single.deinit(std.testing.allocator);
    for (plain) |byte| {
        if (filter.feed(&.{byte})) |ready| {
            try single.appendSlice(std.testing.allocator, ready.bytes);
            try single.appendSlice(std.testing.allocator, ready.remainder);
        }
    }
    try std.testing.expectEqualStrings(expected, single.items);
    // Once the first receipt has ended the window, normal output is untouched.
    const normal = filter.feed(header).?;
    try std.testing.expectEqualStrings(header, normal.bytes);
}

test "initializer echo filter accepts only complete known wrapped echo" {
    const header = "_zwR() { _zwP='0123'; }; _zwR\n";
    const ack = "\x1b]133;P;zw_init=0123;1;128\x07";
    const wrapped = "_\x08_zwR() { _zwP='0 \r\x1b[K1\r123'; }; _zwR\x1b[?2004l\r\r\n";
    var filter: EchoFilter = .{};
    filter.arm(header, "0123");
    const ready = filter.feed("prompt> " ++ wrapped ++ ack).?;
    try std.testing.expectEqualStrings("prompt> \x1b[?2004l\r\r\n" ++ ack, ready.bytes);
    // Mismatched nonce, truncated source, trailing text, and another program's
    // line are never removed merely because they occur before the receipt.
    const untouched = "_zwR() { _zwP='0124'; }; _zwR\r\n" ++
        "_zwR() { _zwP='0123';\r\n" ++
        "_zwR() {  _zwP='0123'; }; _zwR\r\n" ++
        "_zwR() { _zwP='0123'; }; _zwR EXTRA\r\n" ++
        "PROGRAM OUTPUT\r\n" ++ ack ++ header;
    filter.arm(header, "0123");
    try std.testing.expectEqualStrings(untouched, filter.feed(untouched).?.bytes);
}

test "initializer echo filter timeout and capacity release original bytes" {
    const header = "_zwR() { _zwP='0123'; }; _zwR\n";
    var filter: EchoFilter = .{};
    filter.arm(header, "0123");
    try std.testing.expect(filter.feed(header) == null);
    try std.testing.expectEqualStrings(header, filter.finish());
    try std.testing.expectEqualStrings("", filter.finish());
    filter.arm(header, "0123");
    try std.testing.expect(filter.feed("banner\r\n") == null);
    const large: [EchoFilter.capacity]u8 = @splat('x');
    const ready = filter.feed(&large).?;
    try std.testing.expectEqualStrings("banner\r\n", ready.bytes);
    try std.testing.expectEqualSlices(u8, &large, ready.remainder);
    try std.testing.expect(!filter.active);
}

test "initializer echo filter handles Bash redraw at every source boundary" {
    const a = std.testing.allocator;
    const nonce = "00112233445566778899aabbccddeeff";
    const chunks = try initializerChunks(a, nonce);
    defer {
        for (chunks) |chunk| a.free(chunk);
        a.free(chunks);
    }
    const header = std.mem.trimEnd(u8, chunks[0], "\n");
    const ack = "\x1b]133;P;zw_init=" ++ nonce ++ ";1;128\x07";
    // Real Readline wraps can duplicate any character, including the first
    // of adjacent equal source characters. Older versions use space + CR.
    for (1..header.len + 1) |boundary| {
        for ([_]bool{ false, true }) |padding| {
            const echo = try std.fmt.allocPrint(a, "banner\r\nprompt> {s}{s}\r{s}{s}\r\n{s}after\r\n", .{
                header[0..boundary],
                if (padding) " " else "",
                if (padding) "" else header[boundary - 1 .. boundary],
                header[boundary..],
                ack,
            });
            defer a.free(echo);
            var filter: EchoFilter = .{};
            filter.arm(chunks[0], nonce);
            // Split a native read inside the wrap sequence as well.
            const split = "banner\r\nprompt> ".len + boundary + 1;
            try std.testing.expect(filter.feed(echo[0..split]) == null);
            // Whitespace after the complete command belongs to its terminator.
            const expected = if (padding and boundary == header.len)
                "banner\r\nprompt>  \r\r\n" ++ ack ++ "after\r\n"
            else
                "banner\r\nprompt> \r\n" ++ ack ++ "after\r\n";
            try std.testing.expectEqualStrings(expected, filter.feed(echo[split..]).?.bytes);
        }
    }
}
