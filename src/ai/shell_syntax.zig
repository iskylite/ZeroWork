//! Bounded streaming shell parser. It emits complete simple commands and
//! nested command-substitution scripts without executing or expanding them.
const std = @import("std");

pub const Command = struct {
    words: []const Word,
    has_here_document: bool,
    has_process_substitution: bool,
    input: Input = .{},
    output_redirected: bool = false,
    prompts: []const []const u8 = &.{},
    straight_line: bool = false,
};
pub const Document = struct { body: []const u8, quoted: bool, strip_tabs: bool };
pub const InputPart = union(enum) { unknown, document: Document, literal: []const u8 };
pub const Pipeline = enum { none, stdout, combined };
pub const Input = struct { pipeline: Pipeline = .none, redirections: []const InputPart = &.{} };

/// Return the exact document bytes only when shell expansion cannot change
/// them. The caller provides storage at least as large as the original body.
pub fn literalDocument(document: Document, buffer: []u8) ?[]const u8 {
    if (buffer.len < document.body.len) return null;
    var at: usize = 0;
    var len: usize = 0;
    var line_start = true;
    while (at < document.body.len) {
        if (line_start and document.strip_tabs) {
            while (at < document.body.len and document.body[at] == '\t') at += 1;
            if (at == document.body.len) break;
        }
        line_start = false;
        const c = document.body[at];
        at += 1;
        if (!document.quoted) {
            if (c == '$' or c == '`') return null;
            if (c == '\\' and at < document.body.len) {
                const next = document.body[at];
                if (next == '\n') {
                    at += 1;
                    continue;
                }
                if (std.mem.indexOfScalar(u8, "\\$`", next) != null) {
                    buffer[len] = next;
                    len += 1;
                    at += 1;
                    continue;
                }
            }
        }
        buffer[len] = c;
        len += 1;
        if (c == '\n') line_start = true;
    }
    return buffer[0..len];
}
pub const Sink = struct {
    context: *anyopaque,
    command: *const fn (*anyopaque, Command) void,
    nested: *const fn (*anyopaque, []const u8, u8) void,
    arithmetic: *const fn (*anyopaque, []const u8, u8) void,
    session_variable: ?*const fn (*anyopaque) void = null,
};

pub const Word = struct { text: []const u8, dynamic: bool = false, tilde: bool = false, assignment: bool = false, session_assignment: bool = false, process_substitution: bool = false, reserved: bool = false };
const Separator = enum { pipe, pipe_and_stderr, list, continued_list, case_terminator, open_group, close_group, newline };
const Redirect = struct { fd: ?u32, here_document: bool, here_string: bool = false };
const Token = union(enum) { word: Word, arithmetic, separator: Separator, redirect: Redirect, end };
const max_here_documents = 32;
const max_delimiter_bytes = 256;
const HereDocument = struct {
    delimiter: [max_delimiter_bytes]u8 = undefined,
    len: usize = 0,
    quoted: bool = false,
    strip_tabs: bool = false,
    body: ?[]const u8 = null,

    fn text(self: *const HereDocument) []const u8 {
        return self.delimiter[0..self.len];
    }
};
const Delimiter = struct { document: HereDocument, end: usize };

/// Indirection, Zsh evaluation flags, and Bash prompt transformation can
/// interpret the contents of a variable as more than ordinary data.
fn parameterMayEvaluate(input: []const u8, start: usize) bool {
    if (start >= input.len) return false;
    if (input[start] == '(') return true;
    if (input[start] == '!' and start + 1 < input.len and input[start + 1] != '}') {
        // These two forms enumerate names or array keys; unlike ${!name},
        // they do not use the variable's value as another variable name.
        var end = start + 1;
        if (end < input.len and (std.ascii.isAlphabetic(input[end]) or input[end] == '_')) {
            end += 1;
            while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_')) end += 1;
            if (end + 1 < input.len and (input[end] == '*' or input[end] == '@') and input[end + 1] == '}') return false;
            if (end + 3 < input.len and input[end] == '[' and (input[end + 1] == '*' or input[end + 1] == '@') and input[end + 2] == ']' and input[end + 3] == '}') return false;
        }
        return true;
    }
    var at = start;
    // The length operator still evaluates an indexed array subscript.
    if (input[at] == '#' and at + 1 < input.len and input[at + 1] != '}') at += 1;
    if (std.ascii.isAlphabetic(input[at]) or input[at] == '_') {
        at += 1;
        while (at < input.len and (std.ascii.isAlphanumeric(input[at]) or input[at] == '_')) at += 1;
    } else if (std.ascii.isDigit(input[at]) or std.mem.indexOfScalar(u8, "@*#?-$!", input[at]) != null) {
        at += 1;
    } else return false;
    if (at < input.len and input[at] == '[') {
        at += 1;
        while (at < input.len and input[at] != ']') : (at += 1) {
            const c = input[at];
            if (std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c == '`' or c == '\'' or c == '"' or c >= 128) return true;
        }
        if (at == input.len) return true;
        at += 1;
    }
    // Substring offsets and lengths are arithmetic expressions. A variable
    // referenced there can itself contain an evaluated array subscript.
    if (at + 1 < input.len and input[at] == ':' and std.mem.indexOfScalar(u8, "-=+?", input[at + 1]) == null) {
        at += 1;
        while (at < input.len and input[at] != '}') : (at += 1) {
            const c = input[at];
            if (std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c == '`' or c == '\'' or c == '"' or c >= 128) return true;
        }
        return at == input.len;
    }
    return at + 2 < input.len and input[at] == '@' and input[at + 1] == 'P' and input[at + 2] == '}';
}

/// Bash 5.3 also accepts ${ command; } and ${| command; }. Unlike ordinary
/// parameter expansion these execute commands in the current shell.
fn inplaceSubstitution(input: []const u8, dollar: usize) bool {
    if (dollar + 2 >= input.len or input[dollar] != '$' or input[dollar + 1] != '{') return false;
    return input[dollar + 2] == '|' or std.ascii.isWhitespace(input[dollar + 2]);
}

fn promptParameter(input: []const u8, start: usize) ?[]const u8 {
    if (start >= input.len or (!std.ascii.isAlphabetic(input[start]) and input[start] != '_')) return null;
    var end = start + 1;
    while (end < input.len and (std.ascii.isAlphanumeric(input[end]) or input[end] == '_')) end += 1;
    if (end + 2 >= input.len or !std.mem.eql(u8, input[end .. end + 3], "@P}")) return null;
    return input[start..end];
}

fn skipLineContinuations(input: []const u8, start: usize) usize {
    var at = start;
    while (std.mem.startsWith(u8, input[at..], "\\\n")) at += 2;
    return at;
}

/// Named parameters may resolve through a nameref. Positional and special
/// parameters have no user-defined variable attributes.
fn accessesSessionVariable(input: []const u8, after_dollar: usize) bool {
    var at = skipLineContinuations(input, after_dollar);
    if (at == input.len) return false;
    if (input[at] == '{') {
        at = skipLineContinuations(input, at + 1);
        if (at + 1 < input.len and input[at] == '#' and input[at + 1] != '}') {
            at = skipLineContinuations(input, at + 1);
        }
        if (at == input.len) return true;
        const name = input[at];
        if (name == '!') return at + 1 < input.len and input[at + 1] != '}';
        return !std.ascii.isDigit(name) and std.mem.indexOfScalar(u8, "@*#?-$", name) == null;
    }
    return std.ascii.isAlphabetic(input[at]) or input[at] == '_' or input[at] >= 128 or std.mem.indexOfScalar(u8, "^=~", input[at]) != null;
}

/// Recognize variable writes without treating assignment-shaped arguments
/// as assignments. The live-shell check includes indexed and append forms.
fn sessionAssignment(raw: []const u8, depth: u8, comments: bool) bool {
    if (raw.len == 0 or (!std.ascii.isAlphabetic(raw[0]) and raw[0] != '_')) return false;
    var at = skipLineContinuations(raw, 1);
    while (at < raw.len and (std.ascii.isAlphanumeric(raw[at]) or raw[at] == '_')) at = skipLineContinuations(raw, at + 1);
    if (at < raw.len and raw[at] == '[') {
        at = closing(raw, at + 1, ']', depth + 1, false, comments) orelse return false;
        at = skipLineContinuations(raw, at + 1);
    }
    if (at < raw.len and raw[at] == '+') at = skipLineContinuations(raw, at + 1);
    return at < raw.len and raw[at] == '=';
}

fn isControlWord(word: []const u8) bool {
    for ([_][]const u8{ "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac", "select", "function", "time", "coproc", "repeat", "!" }) |keyword| {
        if (std.mem.eql(u8, word, keyword)) return true;
    }
    return false;
}

const Lexer = struct {
    input: []const u8,
    at: usize = 0,
    depth: u8,
    sink: Sink,
    comments: bool,
    uncertain: bool = false,
    here_documents: [max_here_documents]HereDocument = undefined,
    here_document_count: usize = 0,
    expect_delimiter: bool = false,
    strip_tabs: bool = false,
    io_number: ?u32 = null,
    io_number_invalid: bool = false,
    arithmetic_allowed: bool = false,
    capture_prompts: bool = false,
    prompts: [256][]const u8 = undefined,
    prompt_count: usize = 0,
    buffer: [16384]u8 = undefined,

    fn next(self: *Lexer) Token {
        while (self.at < self.input.len) {
            const c = self.input[self.at];
            if (c == ' ' or c == '\t') {
                self.at += 1;
                continue;
            }
            if (c == '\\' and self.at + 1 < self.input.len and self.input[self.at + 1] == '\n') {
                self.at += 2;
                continue;
            }
            if (c == '#' and self.comments) {
                while (self.at < self.input.len and self.input[self.at] != '\n') self.at += 1;
                continue;
            }
            break;
        }
        if (self.at == self.input.len) return .end;
        if (self.expect_delimiter) {
            self.expect_delimiter = false;
            return self.hereDelimiter();
        }
        if (self.input[self.at] == '\n') {
            self.at += 1;
            return .{ .separator = .newline };
        }
        if (std.mem.startsWith(u8, self.input[self.at..], "&>")) {
            self.at += 2;
            if (self.at < self.input.len and self.input[self.at] == '>') self.at += 1;
            return .{ .redirect = .{ .fd = 1, .here_document = false } };
        }
        if (self.arithmetic_allowed and std.mem.startsWith(u8, self.input[self.at..], "((")) {
            const begin = self.at + 2;
            const end = closing(self.input, self.at + 1, ')', self.depth + 1, false, self.comments) orelse {
                self.uncertain = true;
                self.at = self.input.len;
                return .end;
            };
            if (end == begin or self.input[end - 1] != ')') {
                self.uncertain = true;
            } else {
                self.sink.arithmetic(self.sink.context, self.input[begin .. end - 1], self.depth + 1);
            }
            self.at = end + 1;
            return .arithmetic;
        }
        const current = self.input[self.at];
        const brace_word = (current == '{' or current == '}') and self.at + 1 < self.input.len and
            ((current == '{' and self.input[self.at + 1] == '}') or
                std.mem.indexOfScalar(u8, " \t;|&\n\r(){}<>", self.input[self.at + 1]) == null);
        if (!brace_word and std.mem.indexOfScalar(u8, ";|&\n\r(){}", current) != null) {
            self.at += 1;
            const separator: Separator = switch (current) {
                ';' => if (self.at < self.input.len and (self.input[self.at] == ';' or self.input[self.at] == '&' or self.input[self.at] == '|')) blk: {
                    const second = self.input[self.at];
                    self.at += 1;
                    if (second == ';' and self.at < self.input.len and self.input[self.at] == '&') self.at += 1;
                    break :blk .case_terminator;
                } else .list,
                '|' => if (self.at < self.input.len and self.input[self.at] == '|') blk: {
                    self.at += 1;
                    break :blk .continued_list;
                } else if (self.at < self.input.len and self.input[self.at] == '&') blk: {
                    self.at += 1;
                    break :blk .pipe_and_stderr;
                } else .pipe,
                '&' => if (self.at < self.input.len and self.input[self.at] == '&') blk: {
                    self.at += 1;
                    break :blk .continued_list;
                } else .list,
                '(', '{' => .open_group,
                ')', '}' => .close_group,
                else => .list,
            };
            return .{ .separator = separator };
        }
        if ((self.input[self.at] == '>' or self.input[self.at] == '<') and !self.processStart()) {
            const input_redirect = self.input[self.at] == '<';
            const fd: ?u32 = if (self.io_number_invalid) null else self.io_number orelse if (input_redirect) @as(u32, 0) else 1;
            self.io_number = null;
            self.io_number_invalid = false;
            self.at += 1;
            if (self.at < self.input.len) {
                const next_byte = self.input[self.at];
                if (input_redirect and next_byte == '<') {
                    self.at += 1;
                    if (self.at < self.input.len and self.input[self.at] == '<') {
                        self.at += 1;
                        return .{ .redirect = .{ .fd = fd, .here_document = false, .here_string = true } };
                    } else {
                        self.strip_tabs = self.at < self.input.len and self.input[self.at] == '-';
                        if (self.strip_tabs) self.at += 1;
                        self.expect_delimiter = true;
                        return .{ .redirect = .{ .fd = fd, .here_document = true } };
                    }
                } else if (next_byte == '>' or next_byte == '&' or (!input_redirect and next_byte == '|')) {
                    self.at += 1;
                }
            }
            return .{ .redirect = .{ .fd = fd, .here_document = false } };
        }
        const start = self.at;
        var word: Word = .{ .text = "", .tilde = self.input[self.at] == '~' };
        var quote: u8 = 0;
        var parameter: usize = 0;
        var len: usize = 0;
        var pattern = false;
        var quoted = false;
        while (self.at < self.input.len) {
            var c = self.input[self.at];
            const process = quote == 0 and parameter == 0 and self.processStart();
            if (!process and quote == 0 and parameter == 0 and std.mem.indexOfScalar(u8, " \t;|&\n\r()><", c) != null) break;
            self.at += 1;
            if (process) {
                const begin = self.at + 1;
                const end = closing(self.input, begin, ')', self.depth + 1, true, self.comments) orelse {
                    self.uncertain = true;
                    break;
                };
                self.sink.nested(self.sink.context, self.input[begin..end], self.depth + 1);
                word.dynamic = true;
                word.process_substitution = true;
                self.at = end + 1;
                c = '$';
            } else if (c == '\\' and quote != '\'') {
                if (self.at == self.input.len) {
                    self.uncertain = true;
                    break;
                }
                const escaped = self.input[self.at];
                if (quote == 0 or std.mem.indexOfScalar(u8, "$`\"\\\n", escaped) != null) {
                    self.at += 1;
                    if (escaped == '\n') continue;
                    quoted = true;
                    c = escaped;
                }
            } else if (c == '\'' or c == '"') {
                if (quote == 0) {
                    quoted = true;
                    quote = c;
                    continue;
                }
                if (quote == c) {
                    quote = 0;
                    continue;
                }
            } else if (quote != '\'' and (c == '`' or (c == '$' and self.at < self.input.len and self.input[self.at] == '('))) {
                const begin = self.at + @as(usize, if (c == '$') 1 else 0);
                const end = closing(self.input, begin, if (c == '$') ')' else '`', self.depth + 1, false, self.comments) orelse {
                    self.uncertain = true;
                    self.at = self.input.len;
                    break;
                };
                if (c == '$' and begin < end and self.input[begin] == '(') {
                    self.sink.arithmetic(self.sink.context, self.input[begin..end], self.depth + 1);
                } else {
                    self.sink.nested(self.sink.context, self.input[begin..end], self.depth + 1);
                }
                word.dynamic = true;
                self.at = end + 1;
                c = '$';
            } else if (c == '$' and quote != '\'' and self.at < self.input.len and self.input[self.at] == '[') {
                const begin = self.at + 1;
                const end = closing(self.input, begin, ']', self.depth + 1, false, self.comments) orelse {
                    self.uncertain = true;
                    self.at = self.input.len;
                    break;
                };
                self.sink.arithmetic(self.sink.context, self.input[begin..end], self.depth + 1);
                word.dynamic = true;
                self.at = end + 1;
                c = '$';
            } else if (c == '$' and quote != '\'' and inplaceSubstitution(self.input, self.at - 1)) {
                var begin = self.at + 1;
                if (self.input[begin] == '|') begin += 1;
                const end = closing(self.input, begin, '}', self.depth + 1, false, self.comments) orelse {
                    self.uncertain = true;
                    self.at = self.input.len;
                    break;
                };
                self.sink.nested(self.sink.context, self.input[begin..end], self.depth + 1);
                // This form runs in the parent shell and can alter its state.
                self.uncertain = true;
                word.dynamic = true;
                self.at = end + 1;
                c = '$';
            } else if (c == '$' and quote != '\'') {
                word.dynamic = true;
                if (self.sink.session_variable) |access| {
                    if (accessesSessionVariable(self.input, self.at)) access(self.sink.context);
                }
                if (self.at < self.input.len and self.input[self.at] == '{') {
                    if (parameterMayEvaluate(self.input, self.at + 1)) {
                        if (self.capture_prompts) {
                            if (promptParameter(self.input, self.at + 1)) |name| {
                                if (self.prompt_count == self.prompts.len) {
                                    self.uncertain = true;
                                } else {
                                    self.prompts[self.prompt_count] = name;
                                    self.prompt_count += 1;
                                }
                            } else self.uncertain = true;
                        } else self.uncertain = true;
                    }
                    parameter += 1;
                    self.at += 1;
                }
            } else if (c == '}' and parameter != 0 and quote != '\'') {
                parameter -= 1;
            } else if (quote == 0 and std.mem.indexOfScalar(u8, "*?[{}", c) != null) {
                // An empty brace pair is literal in the supported shells;
                // unlike a brace expression it cannot expand into words.
                const empty_brace = (c == '{' and self.at < self.input.len and self.input[self.at] == '}') or
                    (c == '}' and self.at >= 2 and self.input[self.at - 2] == '{');
                pattern = pattern or !empty_brace;
            }
            if (len == self.buffer.len or c == 0) {
                self.uncertain = true;
                self.at = self.input.len;
                break;
            }
            self.buffer[len] = c;
            len += 1;
        }
        if (quote != 0 or parameter != 0) self.uncertain = true;
        word.text = self.buffer[0..len];
        // `[` and `[[` are shell test commands; glob patterns in other
        // command names or removal operands depend on the live filesystem.
        if (pattern and !std.mem.eql(u8, word.text, "[") and !std.mem.eql(u8, word.text, "[[")) word.dynamic = true;
        word.reserved = !quoted and !word.dynamic;
        const raw = self.input[start..self.at];
        if (len != 0 and self.at < self.input.len and (self.input[self.at] == '>' or self.input[self.at] == '<')) {
            const io_number = for (raw) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;
            if (io_number) {
                self.io_number = std.fmt.parseInt(u32, raw, 10) catch blk: {
                    self.io_number_invalid = true;
                    break :blk null;
                };
                return self.next();
            }
        }
        if (std.mem.indexOfScalar(u8, raw, '=')) |equal| {
            word.assignment = equal > 0 and (std.ascii.isAlphabetic(raw[0]) or raw[0] == '_');
            for (raw[0..equal]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') {
                word.assignment = false;
                break;
            };
        }
        if (self.sink.session_variable != null) word.session_assignment = word.assignment or sessionAssignment(raw, self.depth, self.comments);
        return .{ .word = word };
    }

    fn processStart(self: *const Lexer) bool {
        return std.mem.startsWith(u8, self.input[self.at..], "<(") or
            std.mem.startsWith(u8, self.input[self.at..], ">(");
    }

    fn hereDelimiter(self: *Lexer) Token {
        const start = self.at;
        const parsed = readDelimiter(self.input, start, self.strip_tabs) orelse {
            self.uncertain = true;
            self.at = start;
            return self.next();
        };
        self.at = parsed.end;
        if (self.here_document_count == self.here_documents.len) {
            self.uncertain = true;
        } else {
            self.here_documents[self.here_document_count] = parsed.document;
            self.here_document_count += 1;
        }
        // The delimiter is a redirection target, never a command word.
        return .{ .word = .{ .text = "" } };
    }

    fn hereBody(self: *Lexer, document: *HereDocument) bool {
        const body = hereBodyRange(self.input, self.at, document.*) orelse {
            self.uncertain = true;
            return false;
        };
        document.body = self.input[self.at..body.content_end];
        if (!document.quoted) self.inspectHereExpansions(document.body.?);
        self.at = body.end;
        return true;
    }

    fn consumeHereDocuments(self: *Lexer, first: usize) bool {
        for (self.here_documents[first..self.here_document_count]) |*document| {
            if (!self.hereBody(document)) {
                self.at = self.input.len;
                return false;
            }
        }
        return true;
    }

    fn inspectHereExpansions(self: *Lexer, body: []const u8) void {
        // Unquoted here-documents remove backslash-newline before expansion.
        // Normalize a private copy so a substitution split across lines is
        // inspected as the same command that the shell will see.
        const normalized = std.heap.page_allocator.alloc(u8, body.len) catch {
            self.uncertain = true;
            return;
        };
        defer std.heap.page_allocator.free(normalized);
        var input_at: usize = 0;
        var used: usize = 0;
        while (input_at < body.len) {
            if (body[input_at] == '\\' and input_at + 1 < body.len) {
                if (body[input_at + 1] == '\n') {
                    input_at += 2;
                    continue;
                }
                normalized[used] = body[input_at];
                normalized[used + 1] = body[input_at + 1];
                used += 2;
                input_at += 2;
                continue;
            }
            normalized[used] = body[input_at];
            used += 1;
            input_at += 1;
        }
        self.inspectNormalizedHereExpansions(normalized[0..used]);
    }

    fn inspectNormalizedHereExpansions(self: *Lexer, body: []const u8) void {
        var at: usize = 0;
        while (at < body.len) : (at += 1) {
            const c = body[at];
            if (c == '\\' and at + 1 < body.len and std.mem.indexOfScalar(u8, "\\$`", body[at + 1]) != null) {
                at += 1;
                continue;
            }
            if (c == '$') if (self.sink.session_variable) |access| {
                if (accessesSessionVariable(body, at + 1)) access(self.sink.context);
            };
            const dollar_paren = c == '$' and at + 1 < body.len and body[at + 1] == '(';
            const dollar_bracket = c == '$' and at + 1 < body.len and body[at + 1] == '[';
            if (dollar_bracket) {
                const begin = at + 2;
                const end = closing(body, begin, ']', self.depth + 1, true, self.comments) orelse {
                    self.uncertain = true;
                    continue;
                };
                self.sink.arithmetic(self.sink.context, body[begin..end], self.depth + 1);
                at = end;
            } else if (dollar_paren or c == '`') {
                const begin = at + @as(usize, if (dollar_paren) 2 else 1);
                const end = closing(body, begin, if (dollar_paren) ')' else '`', self.depth + 1, true, self.comments) orelse {
                    self.uncertain = true;
                    continue;
                };
                if (dollar_paren and begin < end and body[begin] == '(') {
                    self.sink.arithmetic(self.sink.context, body[begin..end], self.depth + 1);
                } else {
                    self.sink.nested(self.sink.context, body[begin..end], self.depth + 1);
                }
                at = end;
            } else if (inplaceSubstitution(body, at)) {
                var begin = at + 2;
                if (body[begin] == '|') begin += 1;
                const end = closing(body, begin, '}', self.depth + 1, false, self.comments) orelse {
                    self.uncertain = true;
                    continue;
                };
                self.sink.nested(self.sink.context, body[begin..end], self.depth + 1);
                self.uncertain = true;
                at = end;
            } else if (c == '$' and at + 1 < body.len and body[at + 1] == '{') {
                if (!supportedHereParameter(body, at, self.depth + 1, self.comments)) self.uncertain = true;
            }
        }
    }
};

/// Prompt expansion treats quotes as data, like an unquoted here-document,
/// but first processes backslash escapes. Leave those for confirmation.
pub fn inspectPrompt(value: []const u8, depth: u8, sink: Sink, comments: bool) bool {
    if (depth >= 8 or std.mem.indexOfScalar(u8, value, '\\') != null) return false;
    var lexer: Lexer = .{ .input = value, .depth = depth, .sink = sink, .comments = comments };
    lexer.inspectNormalizedHereExpansions(value);
    return !lexer.uncertain;
}

/// Here-document delimiters undergo quote removal, but are not expanded.
fn readDelimiter(input: []const u8, start: usize, strip_tabs: bool) ?Delimiter {
    var document: HereDocument = .{ .strip_tabs = strip_tabs };
    var at = start;
    var quote: u8 = 0;
    var had_word = false;
    while (at < input.len) {
        var c = input[at];
        if (quote == 0 and std.mem.indexOfScalar(u8, " \t\n\r;|&<>()", c) != null) break;
        if (c == '\n' or c == '\r' or c == 0) return null;
        at += 1;
        had_word = true;
        if (c == '\\' and quote != '\'') {
            if (at == input.len) return null;
            const escaped = input[at];
            if (quote == 0 or std.mem.indexOfScalar(u8, "$`\"\\\n", escaped) != null) {
                at += 1;
                if (escaped == '\n') continue;
                document.quoted = true;
                c = escaped;
            }
        } else if (c == '\'' or c == '"') {
            if (quote == 0) {
                quote = c;
                document.quoted = true;
                continue;
            }
            if (quote == c) {
                quote = 0;
                continue;
            }
        } else if (quote == 0 and c == '$' and at < input.len and
            std.mem.indexOfScalar(u8, "('`\"", input[at]) != null)
        {
            // These delimiter forms require additional shell-specific parsing.
            return null;
        }
        if (document.len == document.delimiter.len) return null;
        document.delimiter[document.len] = c;
        document.len += 1;
    }
    if (!had_word or quote != 0 or (at < input.len and
        (std.mem.startsWith(u8, input[at..], "<(") or std.mem.startsWith(u8, input[at..], ">(")))) return null;
    return .{ .document = document, .end = at };
}

fn continuedLine(line: []const u8) bool {
    var at = line.len;
    while (at != 0 and line[at - 1] == '\\') at -= 1;
    return (line.len - at) % 2 != 0;
}

const HereBodyRange = struct { content_end: usize, end: usize };

fn hereBodyRange(input: []const u8, start: usize, document: HereDocument) ?HereBodyRange {
    var at = start;
    while (at < input.len) {
        const line_start = at;
        var matched: usize = 0;
        var matches = true;
        var first_segment = true;
        while (true) {
            const end = std.mem.indexOfScalarPos(u8, input, at, '\n') orelse input.len;
            const line = input[at..end];
            var part = if (document.strip_tabs and first_segment) std.mem.trimStart(u8, line, "\t") else line;
            first_segment = false;
            const joins_next = !document.quoted and end < input.len and continuedLine(part);
            if (joins_next) part = part[0 .. part.len - 1];
            for (part) |c| {
                if (matched >= document.len or document.delimiter[matched] != c) matches = false;
                matched += 1;
            }
            at = @min(end + 1, input.len);
            if (!joins_next) break;
            if (at == input.len) return null;
        }
        if (matches and matched == document.len) return .{ .content_end = line_start, .end = at };
    }
    return null;
}

/// Plain parameter expansions are data. Unsupported operators or malformed
/// nesting stay uncertain; nested command substitutions are visited separately.
fn supportedHereParameter(body: []const u8, start: usize, depth: u8, comments: bool) bool {
    if (depth >= 8) return false;
    var at = start + 2;
    if (at >= body.len) return false;
    if (body[at] == '#' and at + 1 < body.len and body[at + 1] != '}') at += 1;
    if (at >= body.len) return false;
    if (std.ascii.isAlphabetic(body[at]) or body[at] == '_') {
        at += 1;
        while (at < body.len and (std.ascii.isAlphanumeric(body[at]) or body[at] == '_')) at += 1;
    } else if (std.ascii.isDigit(body[at])) {
        at += 1;
        while (at < body.len and std.ascii.isDigit(body[at])) at += 1;
    } else if (std.mem.indexOfScalar(u8, "@*#?-$!", body[at]) != null) {
        at += 1;
    } else return false;
    if (at >= body.len) return false;
    if (body[at] == ':') {
        at += 1;
        if (at >= body.len or std.mem.indexOfScalar(u8, "-=+?", body[at]) == null) return false;
    } else if (std.mem.indexOfScalar(u8, "}-=+?#%/", body[at]) == null) return false;
    return parameterEnd(body, start + 2, depth, comments) != null;
}

fn parameterEnd(body: []const u8, start: usize, depth: u8, comments: bool) ?usize {
    if (depth >= 8) return null;
    var at = start;
    var nesting: usize = 1;
    while (at < body.len) : (at += 1) {
        if (body[at] == '\\' and at + 1 < body.len) {
            at += 1;
        } else if (body[at] == '$' and at + 1 < body.len and body[at + 1] == '{') {
            if (nesting >= 8) return null;
            nesting += 1;
            at += 1;
        } else if (body[at] == '$' and at + 1 < body.len and body[at + 1] == '(') {
            at = closing(body, at + 2, ')', depth + 1, true, comments) orelse return null;
        } else if (body[at] == '`') {
            at = closing(body, at + 1, '`', depth + 1, true, comments) orelse return null;
        } else if (body[at] == '}') {
            nesting -= 1;
            if (nesting == 0) return at;
        }
    }
    return null;
}

/// Older Bash versions also count quotes and parentheses while locating the
/// end of a command substitution containing a here-document. When the body
/// would change that boundary, the actual shell dialect must be confirmed.
fn compatibleNestedHereBody(body: []const u8, depth: u8, comments: bool) bool {
    var at: usize = 0;
    var quote: u8 = 0;
    var parens: usize = 0;
    while (at < body.len) : (at += 1) {
        const c = body[at];
        if (c == '\\' and quote != '\'') {
            if (at + 1 == body.len) return false;
            at += 1;
        } else if (c == '`' and quote != '\'') {
            at = closing(body, at + 1, '`', depth + 1, true, comments) orelse return false;
        } else if (c == '\'' or c == '"') {
            if (quote == 0) quote = c else if (quote == c) quote = 0;
        } else if (quote == 0 and c == '(') {
            parens += 1;
        } else if (quote == 0 and c == ')') {
            if (parens == 0) return false;
            parens -= 1;
        }
    }
    return quote == 0 and parens == 0;
}

fn closing(text: []const u8, start: usize, end: u8, depth: u8, strict: bool, comments: bool) ?usize {
    if (depth >= 8) return null;
    var at = start;
    var quote: u8 = 0;
    var parens: usize = 1;
    var brackets: usize = 1;
    var braces: usize = 1;
    var documents: [max_here_documents]HereDocument = undefined;
    var document_count: usize = 0;
    var word_start = true;
    const arithmetic = end == ']' or (end == ')' and start < text.len and text[start] == '(');
    while (at < text.len) : (at += 1) {
        const c = text[at];
        // Backticks have an extra escape-removal pass before their script is parsed.
        if (end == '`' and c == '\\' and at + 1 < text.len and
            std.mem.indexOfScalar(u8, "\\$`", text[at + 1]) != null) return null;
        if (c == '\\' and quote != '\'') {
            if (quote == 0 and at + 1 < text.len and text[at + 1] != '\n') word_start = false;
            at += 1;
            continue;
        }
        if (end == '`' and c == '`') return if (document_count == 0) at else null;
        if (c == '\'' or c == '"') {
            if (quote == c) {
                quote = 0;
            } else if (quote == 0) {
                quote = c;
                word_start = false;
            }
            continue;
        }
        if (quote == '\'') continue;
        if (comments and !arithmetic and quote == 0 and c == '#' and word_start) {
            // Backquote delimiters have a separate escape-removal pass, so
            // comment boundaries there are not inferred across dialects.
            if (end == '`') return null;
            while (at < text.len and text[at] != '\n') at += 1;
            if (at == text.len) return null;
            at -= 1;
            word_start = true;
            continue;
        }
        if (quote == 0 and c == '\n' and document_count != 0) {
            var next = at + 1;
            for (documents[0..document_count]) |document| {
                const body = hereBodyRange(text, next, document) orelse return null;
                if (end == ')' and !compatibleNestedHereBody(text[next..body.content_end], depth, comments)) return null;
                next = body.end;
            }
            document_count = 0;
            if (next >= text.len) return null;
            at = next - 1;
            word_start = true;
            continue;
        }
        if (quote == 0 and !arithmetic and std.mem.startsWith(u8, text[at..], "<<")) {
            if (std.mem.startsWith(u8, text[at..], "<<<")) {
                at += 2;
                word_start = true;
                continue;
            }
            var delimiter_start = at + 2;
            const strip_tabs = delimiter_start < text.len and text[delimiter_start] == '-';
            if (strip_tabs) delimiter_start += 1;
            while (delimiter_start < text.len and (text[delimiter_start] == ' ' or text[delimiter_start] == '\t')) delimiter_start += 1;
            const parsed = readDelimiter(text, delimiter_start, strip_tabs) orelse return null;
            if (document_count == documents.len) return null;
            documents[document_count] = parsed.document;
            document_count += 1;
            at = parsed.end - 1;
            word_start = false;
            continue;
        }
        if (strict and quote == 0 and (std.mem.startsWith(u8, text[at..], "case") or
            std.mem.startsWith(u8, text[at..], "${"))) return null;
        if (quote == 0) word_start = std.mem.indexOfScalar(u8, " \t\r\n;|&()<>", c) != null;
        if (c == '$' and at + 1 < text.len and text[at + 1] == '(') {
            at = closing(text, at + 2, ')', depth + 1, strict, comments) orelse return null;
        } else if (end == '}' and c == '$' and at + 1 < text.len and text[at + 1] == '{') {
            at = parameterEnd(text, at + 2, depth + 1, comments) orelse return null;
        } else if (c == '`') {
            at = closing(text, at + 1, '`', depth + 1, strict, comments) orelse return null;
        } else if (quote == 0 and end == ')') {
            if (c == '(') parens += 1;
            if (c == ')') {
                parens -= 1;
                if (parens == 0) return if (document_count == 0) at else null;
            }
        } else if (quote == 0 and end == ']') {
            if (c == '[') brackets += 1;
            if (c == ']') {
                brackets -= 1;
                if (brackets == 0) return at;
            }
        } else if (quote == 0 and end == '}') {
            if (c == '{') braces += 1;
            if (c == '}') {
                braces -= 1;
                if (braces == 0) return if (document_count == 0) at else null;
            }
        }
    }
    return null;
}

const max_words = 512;
const max_command_bytes = 65534;
const max_batch_words = 4096;
const max_batch_commands = 1024;
const max_case_depth = 16;
const CaseState = enum { subject, in_keyword, pattern, body };
const CaseFrame = struct {
    state: CaseState = .subject,
    pattern_seen: bool = false,
    need_pattern: bool = false,
    opening: bool = false,
    pattern_depth: usize = 0,
};

fn commandPrefix(words: []const Word) bool {
    for (words) |word| {
        if (!word.reserved) return false;
        var control = false;
        for ([_][]const u8{ "if", "then", "elif", "else", "while", "until", "do", "!", "coproc", "noglob", "nocorrect", "time" }) |name| {
            if (std.mem.eql(u8, word.text, name)) {
                control = true;
                break;
            }
        }
        if (!control) return false;
    }
    return true;
}

fn arithmeticPosition(words: []const Word) bool {
    if (commandPrefix(words)) return true;
    if (words.len != 0 and words[words.len - 1].reserved and std.mem.eql(u8, words[words.len - 1].text, "for")) {
        return commandPrefix(words[0 .. words.len - 1]);
    }
    if (words.len >= 2) {
        const prefix = words[words.len - 2];
        if (prefix.reserved and std.mem.eql(u8, prefix.text, "repeat")) return commandPrefix(words[0 .. words.len - 2]);
        if (prefix.reserved and std.mem.eql(u8, prefix.text, "time") and std.mem.eql(u8, words[words.len - 1].text, "-p")) return commandPrefix(words[0 .. words.len - 2]);
    }
    return false;
}

const InputSource = union(enum) { unknown, document: usize, literal: []const u8 };
const PendingCommand = struct {
    first_word: usize,
    word_count: usize,
    first_input: usize,
    input_count: usize,
    pipeline: Pipeline,
    has_here_document: bool,
    has_process_substitution: bool,
    output_redirected: bool,
    first_prompt: usize,
    prompt_count: usize,
    straight_line: bool,
};

fn emitBatch(sink: Sink, words: []const Word, commands: []const PendingCommand, sources: []const InputSource, parts: []InputPart, documents: []const HereDocument, prompts: []const []const u8) void {
    for (sources, 0..) |source, index| parts[index] = switch (source) {
        .unknown => .unknown,
        .literal => |value| .{ .literal = value },
        .document => |doc| if (doc < documents.len and documents[doc].body != null)
            .{ .document = .{ .body = documents[doc].body.?, .quoted = documents[doc].quoted, .strip_tabs = documents[doc].strip_tabs } }
        else
            .unknown,
    };
    for (commands) |command| {
        sink.command(sink.context, .{
            .words = words[command.first_word..][0..command.word_count],
            .has_here_document = command.has_here_document,
            .has_process_substitution = command.has_process_substitution,
            .input = .{ .pipeline = command.pipeline, .redirections = parts[command.first_input..][0..command.input_count] },
            .output_redirected = command.output_redirected,
            .prompts = prompts[command.first_prompt..][0..command.prompt_count],
            .straight_line = command.straight_line,
        });
    }
}

/// Words in each emitted command are valid only until the callback returns.
/// False means syntax was incomplete or outside the bounded grammar.
pub fn parse(source: []const u8, depth: u8, sink: Sink, comments: bool) bool {
    if (depth >= 8 or source.len > max_command_bytes or std.mem.indexOfScalar(u8, source, 0) != null) return false;
    var lexer: Lexer = .{ .input = source, .depth = depth, .sink = sink, .comments = comments };
    const allocator = std.heap.page_allocator;
    const words = allocator.alloc(Word, @min(source.len + 1, max_batch_words)) catch return false;
    defer allocator.free(words);
    const commands = allocator.alloc(PendingCommand, @min(source.len + 1, max_batch_commands)) catch return false;
    defer allocator.free(commands);
    const sources = allocator.alloc(InputSource, @min(source.len + 1, max_batch_words)) catch return false;
    defer allocator.free(sources);
    const parts = allocator.alloc(InputPart, sources.len) catch return false;
    defer allocator.free(parts);
    const bytes = allocator.alloc(u8, source.len) catch return false;
    defer allocator.free(bytes);
    var count: usize = 0;
    var first_word: usize = 0;
    var command_count: usize = 0;
    var input_count: usize = 0;
    var first_input: usize = 0;
    var first_prompt: usize = 0;
    var used: usize = 0;
    var redirect_target = false;
    var here_string_target: ?usize = null;
    var has_redirection = false;
    var pipeline: Pipeline = .none;
    var output_redirected = false;
    var has_here_document = false;
    var has_process_substitution = false;
    var continuation = false;
    var group_depth: usize = 0;
    var consumed_documents: usize = 0;
    var cases: [max_case_depth]CaseFrame = undefined;
    var case_count: usize = 0;
    var complete = true;
    // Only propagate literal assignments through a straight-line list.
    // Once control flow branches, later runtime values are not inferred.
    var straight_line = true;
    while (true) {
        lexer.arithmetic_allowed = !redirect_target and (case_count == 0 or cases[case_count - 1].state == .body) and arithmeticPosition(words[first_word..count]);
        lexer.capture_prompts = case_count == 0 and !redirect_target;
        const token = lexer.next();
        switch (token) {
            .arithmetic => {
                continuation = false;
                if (count == words.len or count - first_word == max_words) {
                    complete = false;
                } else {
                    words[count] = .{ .text = "((...))" };
                    count += 1;
                }
            },
            .word => |value| {
                continuation = false;
                has_process_substitution = has_process_substitution or value.process_substitution;
                if (redirect_target) {
                    redirect_target = false;
                    if (here_string_target) |index| {
                        if (!value.dynamic and !value.tilde and value.text.len <= bytes.len - used) {
                            @memcpy(bytes[used..][0..value.text.len], value.text);
                            sources[index] = .{ .literal = bytes[used..][0..value.text.len] };
                            used += value.text.len;
                        }
                    }
                    here_string_target = null;
                    continue;
                }
                if (value.reserved and isControlWord(value.text)) straight_line = false;
                if (case_count != 0) {
                    const frame = &cases[case_count - 1];
                    switch (frame.state) {
                        .subject => {
                            frame.state = .in_keyword;
                            continue;
                        },
                        .in_keyword => {
                            if (!value.reserved or !std.mem.eql(u8, value.text, "in")) complete = false;
                            frame.state = .pattern;
                            continue;
                        },
                        .pattern => {
                            if (!frame.pattern_seen and !frame.opening and value.reserved and std.mem.eql(u8, value.text, "esac")) {
                                var at = lexer.at;
                                while (at < source.len and (source[at] == ' ' or source[at] == '\t')) at += 1;
                                var pattern_follows = at < source.len and source[at] == ')';
                                if (at < source.len and source[at] == '|') {
                                    if (std.mem.indexOfAny(u8, source[at + 1 ..], ")\n;")) |offset| {
                                        pattern_follows = source[at + 1 + offset] == ')';
                                    }
                                }
                                if (!pattern_follows) {
                                    case_count -= 1;
                                    continue;
                                }
                            }
                            frame.pattern_seen = true;
                            frame.need_pattern = false;
                            continue;
                        },
                        .body => {
                            if (count == first_word and value.reserved and std.mem.eql(u8, value.text, "esac")) {
                                case_count -= 1;
                                continue;
                            }
                        },
                    }
                }
                if (value.reserved and std.mem.eql(u8, value.text, "case") and commandPrefix(words[first_word..count])) {
                    if (case_count == cases.len) {
                        complete = false;
                    } else {
                        cases[case_count] = .{};
                        case_count += 1;
                    }
                    count = first_word;
                    continue;
                }
                if (count == words.len or count - first_word == max_words or value.text.len > bytes.len - used) {
                    complete = false;
                    continue;
                }
                @memcpy(bytes[used..][0..value.text.len], value.text);
                words[count] = value;
                words[count].text = bytes[used..][0..value.text.len];
                used += value.text.len;
                count += 1;
            },
            .redirect => |redirect| {
                continuation = false;
                if (redirect_target) complete = false;
                redirect_target = true;
                here_string_target = null;
                has_redirection = true;
                has_here_document = has_here_document or redirect.here_document;
                if (redirect.fd == null or redirect.fd.? == 0) {
                    if (input_count == sources.len) {
                        complete = false;
                    } else {
                        sources[input_count] = if (redirect.fd != null and redirect.here_document) .{ .document = lexer.here_document_count } else .unknown;
                        if (redirect.fd != null and redirect.here_string) here_string_target = input_count;
                        input_count += 1;
                    }
                }
                if (redirect.fd == null or redirect.fd.? != 0) {
                    // A descriptor can be duplicated onto the pipeline, so
                    // do not infer a transparent output after redirection.
                    output_redirected = true;
                }
            },
            .separator, .end => {
                const separator: ?Separator = if (token == .separator) token.separator else null;
                if (separator) |sep| {
                    if (sep != .newline and !(sep == .list and source[lexer.at - 1] == ';')) straight_line = false;
                }
                var finish_case_item = false;
                if (case_count != 0 and separator != null) {
                    const frame = &cases[case_count - 1];
                    if ((frame.state == .subject or frame.state == .in_keyword) and separator == .newline) {
                        if (!lexer.consumeHereDocuments(consumed_documents)) complete = false;
                        consumed_documents = lexer.here_document_count;
                        continue;
                    }
                    if (frame.state == .pattern) {
                        switch (separator.?) {
                            .open_group => {
                                if (source[lexer.at - 1] != '(') complete = false;
                                if (!frame.pattern_seen and !frame.opening) {
                                    frame.opening = true;
                                } else {
                                    frame.pattern_depth += 1;
                                }
                                continue;
                            },
                            .close_group => {
                                if (source[lexer.at - 1] != ')') complete = false;
                                if (frame.pattern_depth != 0) {
                                    frame.pattern_depth -= 1;
                                } else {
                                    if (!frame.pattern_seen or frame.need_pattern) complete = false;
                                    frame.state = .body;
                                }
                                continue;
                            },
                            .pipe => {
                                if (!frame.pattern_seen or frame.need_pattern) complete = false;
                                frame.need_pattern = true;
                                continue;
                            },
                            .newline => {},
                            else => {
                                complete = false;
                                continue;
                            },
                        }
                    } else if (separator == .case_terminator) {
                        if (frame.state == .body) finish_case_item = true else complete = false;
                    }
                } else if (separator == .case_terminator) {
                    complete = false;
                }
                if (separator == .newline and continuation) {
                    if (!lexer.consumeHereDocuments(consumed_documents)) complete = false;
                    consumed_documents = lexer.here_document_count;
                    continue;
                }
                if (separator == .open_group and count != first_word) {
                    var at = lexer.at;
                    while (at < source.len and (source[at] == ' ' or source[at] == '\t')) at += 1;
                    // A shell function may replace a later pipeline producer.
                    if (at < source.len and source[at] == ')') complete = false;
                }
                if (redirect_target or (token == .end and (lexer.here_document_count != consumed_documents or lexer.expect_delimiter or continuation))) complete = false;
                if (count != first_word or has_redirection) {
                    if (command_count == commands.len) {
                        complete = false;
                    } else {
                        commands[command_count] = .{
                            .first_word = first_word,
                            .word_count = count - first_word,
                            .first_input = first_input,
                            .input_count = input_count - first_input,
                            .pipeline = pipeline,
                            .has_here_document = has_here_document,
                            .has_process_substitution = has_process_substitution,
                            .output_redirected = output_redirected,
                            .first_prompt = first_prompt,
                            .prompt_count = lexer.prompt_count - first_prompt,
                            .straight_line = straight_line,
                        };
                        command_count += 1;
                    }
                }
                // An interactive shell can continue at the next input line
                // after an assignment fails (for example, readonly).
                if (separator == .newline) straight_line = false;
                first_word = count;
                first_input = input_count;
                first_prompt = lexer.prompt_count;
                redirect_target = false;
                here_string_target = null;
                has_redirection = false;
                pipeline = if (separator == .pipe) .stdout else if (separator == .pipe_and_stderr) .combined else .none;
                output_redirected = false;
                has_here_document = false;
                has_process_substitution = false;
                continuation = separator == .pipe or separator == .pipe_and_stderr or separator == .continued_list;
                if (finish_case_item) cases[case_count - 1] = .{ .state = .pattern };
                if (separator == .open_group) group_depth += 1;
                if (separator == .close_group and group_depth != 0) group_depth -= 1;
                if (separator == .newline or token == .end) {
                    if (separator == .newline and group_depth != 0 and lexer.here_document_count != 0) complete = false;
                    if (!lexer.consumeHereDocuments(consumed_documents)) complete = false;
                    emitBatch(sink, words[0..count], commands[0..command_count], sources[0..input_count], parts[0..input_count], lexer.here_documents[0..lexer.here_document_count], lexer.prompts[0..lexer.prompt_count]);
                    lexer.here_document_count = 0;
                    consumed_documents = 0;
                    count = 0;
                    first_word = 0;
                    command_count = 0;
                    input_count = 0;
                    first_input = 0;
                    first_prompt = 0;
                    lexer.prompt_count = 0;
                    used = 0;
                    pipeline = .none;
                }
                if (token == .end) break;
            },
        }
    }
    return complete and !lexer.uncertain and case_count == 0;
}
