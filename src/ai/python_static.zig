//! Bounded analysis of the literal Python subset used for stdin scripts.
//! Unknown statements or computed process arguments require confirmation.
const std = @import("std");

pub const Risk = enum { ordinary, uncertain, blocked };
pub const Sink = struct {
    context: *anyopaque,
    shell: *const fn (*anyopaque, []const u8) Risk,
    argv: *const fn (*anyopaque, []const []const u8) Risk,
};

const Kind = enum { name, string, number, symbol, newline };
const Token = struct { kind: Kind, text: []const u8, escaped: bool = false };
const max_tokens = 4096;
const max_variables = 64;
const max_arguments = 64;

fn combine(a: Risk, b: Risk) Risk {
    return if (a == .blocked or b == .blocked) .blocked else if (a == .uncertain or b == .uncertain) .uncertain else .ordinary;
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn decodeString(source: []const u8, destination: []u8) ?[]const u8 {
    var at: usize = 0;
    var len: usize = 0;
    while (at < source.len) {
        const c = source[at];
        at += 1;
        if (c != '\\') {
            destination[len] = c;
            len += 1;
            continue;
        }
        if (at == source.len) return null;
        const escaped = source[at];
        at += 1;
        if (escaped == '\n') continue;
        const simple: ?u8 = switch (escaped) {
            '\\', '\'', '"' => escaped,
            'a' => 7,
            'b' => 8,
            'f' => 12,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 11,
            else => null,
        };
        if (simple) |value| {
            destination[len] = value;
            len += 1;
            continue;
        }
        var codepoint: u32 = 0;
        if (escaped >= '0' and escaped <= '7') {
            codepoint = escaped - '0';
            var extra: usize = 0;
            while (extra < 2 and at < source.len and source[at] >= '0' and source[at] <= '7') : (extra += 1) {
                codepoint = codepoint * 8 + source[at] - '0';
                at += 1;
            }
        } else {
            const digits: usize = switch (escaped) {
                'x' => 2,
                'u' => 4,
                'U' => 8,
                else => return null,
            };
            if (digits > source.len - at) return null;
            codepoint = std.fmt.parseInt(u32, source[at..][0..digits], 16) catch return null;
            at += digits;
        }
        if (codepoint > 0x10ffff) return null;
        len += std.unicode.utf8Encode(@intCast(codepoint), destination[len..]) catch return null;
    }
    return destination[0..len];
}

fn tokenize(source: []const u8, tokens: []Token, decoded: []u8) ?usize {
    var at: usize = 0;
    var count: usize = 0;
    var nesting: usize = 0;
    var decoded_len: usize = 0;
    while (at < source.len) {
        const c = source[at];
        if (c == ' ' or c == '\t' or c == '\r') {
            at += 1;
            continue;
        }
        if (c == '\\' and at + 1 < source.len and source[at + 1] == '\n') {
            at += 2;
            continue;
        }
        if (c == '#') {
            while (at < source.len and source[at] != '\n') at += 1;
            continue;
        }
        if (count == tokens.len) return null;
        const start = at;
        at += 1;
        if (c == '\n') {
            if (nesting != 0) continue;
            tokens[count] = .{ .kind = .newline, .text = source[start..at] };
        } else if (isNameStart(c)) {
            while (at < source.len and (isNameStart(source[at]) or std.ascii.isDigit(source[at]))) at += 1;
            tokens[count] = .{ .kind = .name, .text = source[start..at] };
        } else if (std.ascii.isDigit(c)) {
            while (at < source.len and (std.ascii.isDigit(source[at]) or source[at] == '.' or source[at] == '_')) at += 1;
            tokens[count] = .{ .kind = .number, .text = source[start..at] };
        } else if (c == '\'' or c == '"') {
            const triple = at + 1 < source.len and source[at] == c and source[at + 1] == c;
            if (triple) at += 2;
            const content_start = at;
            var escaped = false;
            var closed = false;
            var content_end = at;
            while (at < source.len) {
                if (source[at] == '\\') {
                    escaped = true;
                    at += 1;
                    if (at == source.len) return null;
                    at += 1;
                    continue;
                }
                if (source[at] == c and (!triple or (at + 2 < source.len and source[at + 1] == c and source[at + 2] == c))) {
                    content_end = at;
                    at += if (triple) 3 else 1;
                    closed = true;
                    break;
                }
                if (!triple and source[at] == '\n') return null;
                at += 1;
            }
            if (!closed) return null;
            const raw = source[content_start..content_end];
            if (escaped) {
                if (decodeString(raw, decoded[decoded_len..])) |value| {
                    tokens[count] = .{ .kind = .string, .text = value };
                    decoded_len += value.len;
                } else {
                    tokens[count] = .{ .kind = .string, .text = raw, .escaped = true };
                }
            } else {
                tokens[count] = .{ .kind = .string, .text = raw };
            }
        } else {
            if (c == '(' or c == '[' or c == '{') {
                if (nesting == 128) return null;
                nesting += 1;
            } else if ((c == ')' or c == ']' or c == '}') and nesting != 0) {
                nesting -= 1;
            }
            tokens[count] = .{ .kind = .symbol, .text = source[start..at] };
        }
        count += 1;
    }
    return count;
}

fn is(tokens: []const Token, index: usize, text: []const u8) bool {
    return index < tokens.len and std.mem.eql(u8, tokens[index].text, text) and tokens[index].kind != .string;
}

fn boundary(tokens: []const Token, index: usize) bool {
    return index == tokens.len or tokens[index].kind == .newline or is(tokens, index, ";");
}

const Call = struct { end: usize, risk: Risk };
const Binding = struct { local: []const u8, module: []const u8, method: ?[]const u8 = null };
const Bindings = struct {
    items: [max_variables]Binding = undefined,
    len: usize = 0,

    fn find(self: *const Bindings, name: []const u8) ?Binding {
        for (self.items[0..self.len]) |item| if (std.mem.eql(u8, item.local, name)) return item;
        return null;
    }

    fn put(self: *Bindings, binding: Binding) bool {
        for (self.items[0..self.len]) |*item| {
            if (std.mem.eql(u8, item.local, binding.local)) {
                item.* = binding;
                return true;
            }
        }
        if (self.len == self.items.len) return false;
        self.items[self.len] = binding;
        self.len += 1;
        return true;
    }
};

fn importEnd(tokens: []const Token, start: usize, bindings: *Bindings) ?usize {
    var updated = bindings.*;
    var index = start;
    var from_module: ?[]const u8 = null;
    if (is(tokens, index, "from")) {
        if (index + 2 >= tokens.len or tokens[index + 1].kind != .name or !is(tokens, index + 2, "import")) return null;
        from_module = tokens[index + 1].text;
        if (!isOneOf(from_module.?, &.{ "os", "subprocess" })) return null;
        index += 3;
    } else if (is(tokens, index, "import")) {
        index += 1;
    } else return null;
    var imported = false;
    while (index < tokens.len and tokens[index].kind == .name) {
        const target = tokens[index].text;
        if (from_module == null and !isOneOf(target, &.{ "os", "subprocess" })) return null;
        index += 1;
        var local = target;
        if (is(tokens, index, "as")) {
            index += 1;
            if (index == tokens.len or tokens[index].kind != .name) return null;
            local = tokens[index].text;
            index += 1;
        }
        if (!updated.put(.{ .local = local, .module = from_module orelse target, .method = if (from_module != null) target else null })) return null;
        imported = true;
        if (!is(tokens, index, ",")) break;
        index += 1;
    }
    if (!imported or !boundary(tokens, index)) return null;
    bindings.* = updated;
    return index;
}

/// Recognize calls that launch a shell or an argv vector. All arguments and
/// supported options must be literal; otherwise this is an unknown call.
fn processCall(tokens: []const Token, start: usize, bindings: *const Bindings, sink: Sink) ?Call {
    if (start + 2 >= tokens.len or tokens[start].kind != .name) return null;
    const local = tokens[start].text;
    var module: []const u8 = undefined;
    var method: []const u8 = undefined;
    var index: usize = undefined;
    if (is(tokens, start + 1, ".") and start + 4 < tokens.len and tokens[start + 2].kind == .name and is(tokens, start + 3, "(")) {
        if (bindings.find(local)) |binding| {
            if (binding.method != null) return null;
            module = binding.module;
        } else {
            module = local;
        }
        method = tokens[start + 2].text;
        index = start + 4;
    } else if (is(tokens, start + 1, "(")) {
        const binding = bindings.find(local) orelse return null;
        module = binding.module;
        method = binding.method orelse return null;
        index = start + 2;
    } else return null;
    const shell_call = std.mem.eql(u8, module, "os") and isOneOf(method, &.{ "system", "popen" });
    const subprocess_call = std.mem.eql(u8, module, "subprocess") and isOneOf(method, &.{ "run", "call", "check_call", "check_output", "Popen" });
    if (!shell_call and !subprocess_call) return null;

    var arguments: [max_arguments][]const u8 = undefined;
    var count: usize = 0;
    if (index >= tokens.len) return null;
    if (tokens[index].kind == .string and !tokens[index].escaped) {
        arguments[count] = tokens[index].text;
        count += 1;
        index += 1;
    } else if (subprocess_call and is(tokens, index, "[")) {
        index += 1;
        while (index < tokens.len and !is(tokens, index, "]")) {
            if (count == arguments.len or tokens[index].kind != .string or tokens[index].escaped) return null;
            arguments[count] = tokens[index].text;
            count += 1;
            index += 1;
            if (is(tokens, index, ",")) index += 1 else if (!is(tokens, index, "]")) return null;
        }
        if (!is(tokens, index, "]") or count == 0) return null;
        index += 1;
    } else return null;

    var use_shell = shell_call;
    var saw_shell = false;
    while (is(tokens, index, ",")) {
        index += 1;
        if (is(tokens, index, ")")) break;
        if (!subprocess_call or index + 2 >= tokens.len or tokens[index].kind != .name or !is(tokens, index + 1, "=")) return null;
        const key = tokens[index].text;
        const option = tokens[index + 2];
        if (std.mem.eql(u8, key, "shell")) {
            if (saw_shell or option.kind != .name or !isOneOf(option.text, &.{ "True", "False" })) return null;
            use_shell = std.mem.eql(u8, option.text, "True");
            saw_shell = true;
        } else if (isOneOf(key, &.{ "check", "text", "capture_output", "universal_newlines" })) {
            if (option.kind != .name or !isOneOf(option.text, &.{ "True", "False" })) return null;
        } else return null;
        index += 3;
    }
    if (!is(tokens, index, ")")) return null;
    const risk = if (use_shell) sink.shell(sink.context, arguments[0]) else sink.argv(sink.context, arguments[0..count]);
    return .{ .end = index + 1, .risk = risk };
}

fn isOneOf(text: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, text, name)) return true;
    return false;
}

fn knownVariable(name: []const u8, variables: []const []const u8) bool {
    return isOneOf(name, &.{ "True", "False", "None" }) or isOneOf(name, variables);
}

fn hasSupportedEncoding(source: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    for (0..2) |_| {
        const line = lines.next() orelse break;
        const comment = std.mem.trimStart(u8, line, " \t\x0c");
        if (!std.mem.startsWith(u8, comment, "#")) continue;
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, comment, search, "coding")) |offset| {
            var at = offset + "coding".len;
            search = at;
            if (at == comment.len or (comment[at] != ':' and comment[at] != '=')) continue;
            at += 1;
            while (at < comment.len and (comment[at] == ' ' or comment[at] == '\t')) at += 1;
            const start = at;
            while (at < comment.len and (std.ascii.isAlphanumeric(comment[at]) or std.mem.indexOfScalar(u8, "-_.", comment[at]) != null)) at += 1;
            const encoding = comment[start..at];
            if (!std.ascii.eqlIgnoreCase(encoding, "utf-8") and !std.ascii.eqlIgnoreCase(encoding, "utf8") and
                !std.ascii.eqlIgnoreCase(encoding, "utf_8") and !std.ascii.eqlIgnoreCase(encoding, "ascii")) return false;
        }
    }
    return true;
}

/// Parse literal values and collections, with names limited to earlier
/// literal assignments. Attribute access and arbitrary calls are excluded.
fn valueEnd(tokens: []const Token, start: usize, variables: []const []const u8, depth: u8) ?usize {
    var index = atomEnd(tokens, start, variables, depth) orelse return null;
    while (index < tokens.len and tokens[index].kind == .symbol and isOneOf(tokens[index].text, &.{ "+", "-", "*", "/", "%" })) {
        const operator = tokens[index].text;
        index += 1;
        if ((std.mem.eql(u8, operator, "*") or std.mem.eql(u8, operator, "/")) and is(tokens, index, operator)) index += 1;
        index = atomEnd(tokens, index, variables, depth) orelse return null;
    }
    return index;
}

fn atomEnd(tokens: []const Token, start: usize, variables: []const []const u8, depth: u8) ?usize {
    if (depth >= 16 or start >= tokens.len) return null;
    const token = tokens[start];
    if (token.kind == .string or token.kind == .number) return start + 1;
    if (token.kind == .name and knownVariable(token.text, variables)) return start + 1;
    if ((is(tokens, start, "+") or is(tokens, start, "-")) and start + 1 < tokens.len and tokens[start + 1].kind == .number) return start + 2;
    const end_char: []const u8 = if (is(tokens, start, "[")) "]" else if (is(tokens, start, "(")) ")" else if (is(tokens, start, "{")) "}" else return null;
    var index = start + 1;
    while (!is(tokens, index, end_char)) {
        index = valueEnd(tokens, index, variables, depth + 1) orelse return null;
        if (is(tokens, index, ":")) index = valueEnd(tokens, index + 1, variables, depth + 1) orelse return null;
        if (is(tokens, index, ",")) index += 1 else if (!is(tokens, index, end_char)) return null;
    }
    return index + 1;
}

fn printEnd(tokens: []const Token, start: usize, variables: []const []const u8) ?usize {
    if (!is(tokens, start, "print") or !is(tokens, start + 1, "(")) return null;
    var index = start + 2;
    while (!is(tokens, index, ")")) {
        if (index + 1 < tokens.len and tokens[index].kind == .name and is(tokens, index + 1, "=")) {
            if (!isOneOf(tokens[index].text, &.{ "sep", "end", "flush" })) return null;
            index += 2;
        }
        index = valueEnd(tokens, index, variables, 0) orelse return null;
        if (is(tokens, index, ",")) index += 1 else if (!is(tokens, index, ")")) return null;
    }
    return index + 1;
}

pub fn inspect(source: []const u8, sink: Sink) Risk {
    if (!hasSupportedEncoding(source)) return .uncertain;
    const allocator = std.heap.page_allocator;
    const tokens = allocator.alloc(Token, @min(source.len + 1, max_tokens)) catch return .uncertain;
    defer allocator.free(tokens);
    const decoded = allocator.alloc(u8, source.len) catch return .uncertain;
    defer allocator.free(decoded);
    const count = tokenize(source, tokens, decoded) orelse return .uncertain;
    const items = tokens[0..count];
    var risk: Risk = .ordinary;
    var bindings: Bindings = .{};
    for (0..items.len) |index| {
        if (is(items, index, "from") or is(items, index, "import")) _ = importEnd(items, index, &bindings);
    }
    // Check recognizable process calls even if the surrounding program uses
    // syntax outside the safely evaluable subset.
    for (0..items.len) |index| {
        if (processCall(items, index, &bindings, sink)) |call| risk = combine(risk, call.risk);
    }
    var variables: [max_variables][]const u8 = undefined;
    var variable_count: usize = 0;
    var index: usize = 0;
    while (index < items.len) {
        if (boundary(items, index)) {
            index += 1;
            continue;
        }
        var end: ?usize = null;
        if (is(items, index, "pass")) {
            end = index + 1;
        } else if (is(items, index, "import") or is(items, index, "from")) {
            end = importEnd(items, index, &bindings);
        } else if (index + 1 < items.len and items[index].kind == .name and is(items, index + 1, "=")) {
            const name = items[index].text;
            if (!isOneOf(name, &.{ "print", "os", "subprocess", "True", "False", "None" }) and bindings.find(name) == null and variable_count < variables.len) {
                end = valueEnd(items, index + 2, variables[0..variable_count], 0);
                if (end != null and boundary(items, end.?)) {
                    variables[variable_count] = name;
                    variable_count += 1;
                }
            }
        } else if (processCall(items, index, &bindings, sink)) |call| {
            risk = combine(risk, call.risk);
            end = call.end;
        } else if (items[index].kind == .string) {
            end = index + 1;
        } else if (bindings.find("print") == null) {
            end = printEnd(items, index, variables[0..variable_count]);
        }
        if (end == null or !boundary(items, end.?)) {
            risk = combine(risk, .uncertain);
            while (index < items.len and !boundary(items, index)) index += 1;
        } else {
            index = end.?;
        }
    }
    return risk;
}
