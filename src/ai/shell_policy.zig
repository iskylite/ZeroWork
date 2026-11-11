//! Bounded lexical checks, without evaluating a shell or expanding user data.
//! Dynamic executable names and uninspectable nested scripts require approval.
const std = @import("std");
pub const Risk = enum { ordinary, uncertain, blocked };
fn combine(a: Risk, b: Risk) Risk {
    return if (a == .blocked or b == .blocked) .blocked else if (a == .uncertain or b == .uncertain) .uncertain else .ordinary;
}
const Word = struct { text: []const u8, dynamic: bool = false, tilde: bool = false, assignment: bool = false };
const Token = union(enum) { word: Word, separator, redirect, end };
const Lexer = struct {
    input: []const u8,
    at: usize = 0,
    depth: u8,
    risk: Risk = .ordinary,
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
            if (c == '#') {
                while (self.at < self.input.len and self.input[self.at] != '\n') self.at += 1;
                continue;
            }
            break;
        }
        if (self.at == self.input.len) return .end;
        if (std.mem.indexOfScalar(u8, ";|&\n\r(){}", self.input[self.at]) != null) {
            self.at += 1;
            return .separator;
        }
        if (self.input[self.at] == '>' or self.input[self.at] == '<') {
            const c = self.input[self.at];
            self.at += 1;
            if (self.at < self.input.len and self.input[self.at] == c) {
                if (c == '<') self.risk = combine(self.risk, .uncertain);
                self.at += 1;
            }
            return .redirect;
        }
        const start = self.at;
        var word: Word = .{ .text = "", .tilde = self.input[self.at] == '~' };
        var quote: u8 = 0;
        var parameter: usize = 0;
        var len: usize = 0;
        while (self.at < self.input.len) {
            var c = self.input[self.at];
            if (quote == 0 and parameter == 0 and std.mem.indexOfScalar(u8, " \t;|&\n\r(){}><", c) != null) break;
            self.at += 1;
            if (c == '\\' and quote != '\'') {
                if (self.at == self.input.len) {
                    self.risk = combine(self.risk, .uncertain);
                    break;
                }
                const escaped = self.input[self.at];
                if (quote == 0 or std.mem.indexOfScalar(u8, "$`\"\\\n", escaped) != null) {
                    self.at += 1;
                    if (escaped == '\n') continue;
                    c = escaped;
                }
            } else if (c == '\'' or c == '"') {
                if (quote == 0) {
                    quote = c;
                    continue;
                }
                if (quote == c) {
                    quote = 0;
                    continue;
                }
            } else if (quote != '\'' and (c == '`' or (c == '$' and self.at < self.input.len and self.input[self.at] == '('))) {
                const begin = self.at + @as(usize, if (c == '$') 1 else 0);
                const end = closing(self.input, begin, if (c == '$') ')' else '`', self.depth + 1) orelse {
                    self.risk = combine(self.risk, .uncertain);
                    self.at = self.input.len;
                    break;
                };
                self.risk = combine(self.risk, inspectDepth(self.input[begin..end], self.depth + 1));
                word.dynamic = true;
                self.at = end + 1;
                c = '$';
            } else if (c == '$' and quote != '\'') {
                word.dynamic = true;
                if (self.at < self.input.len and self.input[self.at] == '{') {
                    parameter += 1;
                    self.at += 1;
                }
            } else if (c == '}' and parameter != 0 and quote != '\'') {
                parameter -= 1;
            }
            if (len == self.buffer.len or c == 0) {
                self.risk = combine(self.risk, .uncertain);
                self.at = self.input.len;
                break;
            }
            self.buffer[len] = c;
            len += 1;
        }
        if (quote != 0 or parameter != 0) self.risk = combine(self.risk, .uncertain);
        word.text = self.buffer[0..len];
        if (quote == 0 and !word.dynamic and len != 0 and self.at < self.input.len and (self.input[self.at] == '>' or self.input[self.at] == '<')) {
            const io_number = for (word.text) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;
            if (io_number) return self.next();
        }
        const raw = self.input[start..self.at];
        if (std.mem.indexOfScalar(u8, raw, '=')) |equal| {
            word.assignment = equal > 0 and (std.ascii.isAlphabetic(raw[0]) or raw[0] == '_');
            for (raw[0..equal]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') {
                word.assignment = false;
                break;
            };
        }
        return .{ .word = word };
    }
};

fn closing(text: []const u8, start: usize, end: u8, depth: u8) ?usize {
    if (depth >= 8) return null;
    var at = start;
    var quote: u8 = 0;
    var parens: usize = 1;
    while (at < text.len) : (at += 1) {
        const c = text[at];
        if (c == '\\' and quote != '\'') {
            at += 1;
            continue;
        }
        if (end == '`' and c == '`') return at;
        if (c == '\'' or c == '"') {
            if (quote == c) quote = 0 else if (quote == 0) quote = c;
            continue;
        }
        if (quote == '\'') continue;
        if (c == '$' and at + 1 < text.len and text[at + 1] == '(') {
            at = closing(text, at + 2, ')', depth + 1) orelse return null;
        } else if (c == '`') {
            at = closing(text, at + 1, '`', depth + 1) orelse return null;
        } else if (quote == 0 and end == ')') {
            if (c == '(') parens += 1;
            if (c == ')') {
                parens -= 1;
                if (parens == 0) return at;
            }
        }
    }
    return null;
}

pub fn inspect(command: []const u8) Risk {
    return inspectDepth(command, 0);
}
fn inspectDepth(command: []const u8, depth: u8) Risk {
    if (depth >= 8) return .uncertain;
    var lexer: Lexer = .{ .input = command, .depth = depth };
    var kind: enum { none, other, remove, shell, script, eval } = .none;
    var risk: Risk = .ordinary;
    var skip_argument = false;
    var recursive = false;
    var force = false;
    var absolute = false;
    var dynamic_path = false;
    var flags = true;
    var eval_buffer: [16384]u8 = undefined;
    var eval_len: usize = 0;
    while (true) {
        const token = lexer.next();
        risk = combine(risk, lexer.risk);
        switch (token) {
            .end, .separator => {
                if (kind == .remove and recursive and force) risk = combine(risk, if (absolute) .blocked else if (dynamic_path) .uncertain else .ordinary);
                if (kind == .eval) risk = combine(risk, inspectDepth(eval_buffer[0..eval_len], depth + 1));
                if (kind == .script or skip_argument) risk = combine(risk, .uncertain);
                if (token == .end) return risk;
                kind = .none;
                recursive = false;
                force = false;
                absolute = false;
                dynamic_path = false;
                flags = true;
                eval_len = 0;
                skip_argument = false;
            },
            .redirect => {
                skip_argument = true;
            },
            .word => |word| {
                if (skip_argument) {
                    skip_argument = false;
                    continue;
                }
                const text = word.text;
                switch (kind) {
                    .none => {
                        if (word.assignment) continue;
                        if (word.dynamic) {
                            risk = combine(risk, .uncertain);
                            kind = .other;
                            continue;
                        }
                        const name = std.fs.path.basename(text);
                        var wrapper = false;
                        for ([_][]const u8{ "if", "then", "elif", "else", "while", "until", "do", "!", "sudo", "doas", "command", "exec", "env", "nohup" }) |prefix| if (std.mem.eql(u8, name, prefix)) {
                            wrapper = true;
                            break;
                        };
                        if (wrapper) continue;
                        if (std.mem.startsWith(u8, text, "-")) {
                            for ([_][]const u8{ "-u", "-g", "--user", "--group" }) |option| if (std.mem.eql(u8, text, option)) {
                                skip_argument = true;
                                break;
                            };
                            // Unknown wrapper option arity must not conceal the executable.
                            if (!skip_argument and !std.mem.eql(u8, text, "--") and !std.mem.eql(u8, text, "-n") and !std.mem.eql(u8, text, "-i")) risk = combine(risk, .uncertain);
                            continue;
                        }
                        if (std.mem.startsWith(u8, name, "mkfs") or std.mem.startsWith(u8, name, "shutdown")) return .blocked;
                        kind = if (std.mem.eql(u8, name, "rm")) .remove else if (std.mem.eql(u8, name, "eval")) .eval else .other;
                        for ([_][]const u8{ "sh", "bash", "zsh", "dash", "ksh" }) |shell| if (std.mem.eql(u8, name, shell)) {
                            kind = .shell;
                            break;
                        };
                    },
                    .remove => {
                        if (word.dynamic) {
                            dynamic_path = true;
                            risk = combine(risk, .uncertain);
                        }
                        if (flags and std.mem.eql(u8, text, "--")) {
                            flags = false;
                            continue;
                        }
                        if (flags and std.mem.eql(u8, text, "--recursive")) recursive = true else if (flags and std.mem.eql(u8, text, "--force")) force = true else if (flags and text.len > 1 and text[0] == '-' and text[1] != '-') {
                            recursive = recursive or std.mem.indexOfAny(u8, text[1..], "rR") != null;
                            force = force or std.mem.indexOfScalar(u8, text[1..], 'f') != null;
                        } else absolute = absolute or word.tilde or std.fs.path.isAbsolute(text);
                    },
                    .shell => {
                        if (word.dynamic) risk = combine(risk, .uncertain);
                        if (std.mem.eql(u8, text, "-o") or std.mem.eql(u8, text, "-O") or std.mem.eql(u8, text, "--rcfile") or std.mem.eql(u8, text, "--init-file")) {
                            skip_argument = true;
                        } else if (std.mem.eql(u8, text, "--")) {
                            kind = .other;
                        } else if (std.mem.startsWith(u8, text, "--")) {
                            if (!std.mem.eql(u8, text, "--noprofile") and !std.mem.eql(u8, text, "--norc") and !std.mem.eql(u8, text, "--posix")) risk = combine(risk, .uncertain);
                        } else if (text.len > 1 and text[0] == '-') {
                            if (std.mem.indexOfScalar(u8, text[1..], 'c') != null) kind = .script;
                        } else kind = .other;
                    },
                    .script => {
                        risk = combine(risk, if (word.dynamic) .uncertain else inspectDepth(text, depth + 1));
                        kind = .other;
                    },
                    .eval => {
                        if (word.dynamic or text.len + 1 > eval_buffer.len - eval_len) {
                            risk = combine(risk, .uncertain);
                            continue;
                        }
                        if (eval_len != 0) {
                            eval_buffer[eval_len] = ' ';
                            eval_len += 1;
                        }
                        @memcpy(eval_buffer[eval_len..][0..text.len], text);
                        eval_len += text.len;
                    },
                    .other => {},
                }
            },
        }
    }
}
