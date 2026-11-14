//! Command policy over the bounded, structural shell parser. Parsing never
//! executes shell text; an ordinary result is not a general security sandbox.
const std = @import("std");
const syntax = @import("shell_syntax.zig");
const python = @import("python_static.zig");

pub const Risk = python.Risk;

fn combine(a: Risk, b: Risk) Risk {
    return if (a == .blocked or b == .blocked) .blocked else if (a == .uncertain or b == .uncertain) .uncertain else .ordinary;
}

pub fn inspect(command: []const u8) Risk {
    return inspectWithContext(command, 0, false, .{});
}

/// The PTY prompt fence does not attest to variable attributes. Gate explicit
/// accesses to that state before dispatching into the live shell.
pub fn inspectTerminal(command: []const u8) Risk {
    return inspectWithContext(command, 0, false, .{ .live_variables = true });
}

const Context = struct { live_variables: bool = false };

fn inspectWithContext(command: []const u8, depth: u8, inspect_interpreters: bool, context: Context) Risk {
    const normal = inspectCommentMode(command, depth, inspect_interpreters, true, context);
    if (std.mem.indexOfScalar(u8, command, '#') == null) return normal;
    return combine(normal, inspectCommentMode(command, depth, inspect_interpreters, false, context));
}

fn inspectCommentMode(command: []const u8, depth: u8, inspect_interpreters: bool, comments: bool, context: Context) Risk {
    var analysis: Analysis = .{ .depth = depth, .inspect_interpreters = inspect_interpreters, .comments = comments, .context = context };
    const complete = syntax.parse(command, depth, .{
        .context = &analysis,
        .command = Analysis.command,
        .nested = Analysis.nested,
        .arithmetic = Analysis.arithmetic,
        .session_variable = if (context.live_variables) Analysis.sessionVariable else null,
    }, comments);
    return combine(analysis.risk, if (complete) .ordinary else .uncertain);
}

const Analysis = struct {
    depth: u8,
    inspect_interpreters: bool,
    comments: bool,
    context: Context,
    risk: Risk = .ordinary,
    pipe_output: InputStream = .{},
    path_may_change: bool = false,
    numeric_variables: NumericVariables = .{},
    static_variables: StaticVariables = .{},

    fn command(raw: *anyopaque, value: syntax.Command) void {
        const self: *Analysis = @ptrCast(@alignCast(raw));
        const input = resolveInput(value.input, self.pipe_output);
        if (!value.straight_line) self.static_variables.disable();
        for (value.prompts) |name| {
            const prompt = self.static_variables.get(name);
            // The live shell may already have a nameref or other attributes
            // that make the assignment evaluate a different target. A known
            // literal can reveal a forbidden command, but cannot prove that
            // the runtime value or the assignment itself is safe.
            const risk = if (prompt) |text| combine(.uncertain, inspectPromptValue(text, self.depth, self.inspect_interpreters, self.comments)) else Risk.uncertain;
            self.risk = combine(self.risk, risk);
        }
        self.risk = combine(self.risk, self.numeric_variables.inspect(value.words, self.depth, self.inspect_interpreters, self.comments));
        self.risk = combine(self.risk, classifyCommandContext(value, &input, self.depth, false, self.inspect_interpreters, self.comments, self.context));
        self.static_variables.update(value);
        self.path_may_change = self.path_may_change or mayChangeLookup(value.words);
        self.pipe_output = if (!value.output_redirected and isTransparentCat(value.words, self.path_may_change)) input else .{};
    }
    fn nested(raw: *anyopaque, script: []const u8, depth: u8) void {
        const self: *Analysis = @ptrCast(@alignCast(raw));
        self.risk = combine(self.risk, inspectCommentMode(script, depth, self.inspect_interpreters, self.comments, self.context));
    }
    fn arithmetic(raw: *anyopaque, expression: []const u8, depth: u8) void {
        const self: *Analysis = @ptrCast(@alignCast(raw));
        self.risk = combine(self.risk, inspectEvaluatedExpression(expression, depth, self.inspect_interpreters, self.comments));
    }
    fn sessionVariable(raw: *anyopaque) void {
        const self: *Analysis = @ptrCast(@alignCast(raw));
        self.risk = combine(self.risk, .uncertain);
    }
};

/// Track only literal assignment-only commands in a straight-line list.
/// Other commands or dynamic assignments can change shell state.
const StaticVariables = struct {
    const Entry = struct {
        name: [128]u8 = undefined,
        name_len: usize = 0,
        value: [512]u8 = undefined,
        value_len: usize = 0,
    };
    entries: [16]Entry = undefined,
    len: usize = 0,
    enabled: bool = true,

    fn disable(self: *StaticVariables) void {
        self.len = 0;
        self.enabled = false;
    }

    fn get(self: *const StaticVariables, name: []const u8) ?[]const u8 {
        if (!self.enabled) return null;
        for (self.entries[0..self.len]) |*entry| {
            if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) return entry.value[0..entry.value_len];
        }
        return null;
    }

    fn update(self: *StaticVariables, command: syntax.Command) void {
        if (!self.enabled) return;
        if (!command.straight_line or command.words.len == 0 or command.input.redirections.len != 0 or command.output_redirected or command.has_process_substitution) {
            self.disable();
            return;
        }
        for (command.words) |word| {
            if (!word.assignment or word.dynamic or word.tilde) {
                self.disable();
                return;
            }
        }
        for (command.words) |word| {
            const equal = std.mem.indexOfScalar(u8, word.text, '=') orelse {
                self.disable();
                return;
            };
            const name = word.text[0..equal];
            const value = word.text[equal + 1 ..];
            // Tilde and Zsh's equals expansion can make the stored value differ
            // from the lexical word; do not infer either form.
            if (name.len > self.entries[0].name.len or value.len > self.entries[0].value.len or std.mem.indexOfAny(u8, value, "~=") != null) {
                self.disable();
                return;
            }
            var found: ?usize = null;
            for (self.entries[0..self.len], 0..) |*entry, index| {
                if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) {
                    found = index;
                    break;
                }
            }
            const index = found orelse blk: {
                if (self.len == self.entries.len) {
                    self.disable();
                    return;
                }
                const next = self.len;
                self.len += 1;
                break :blk next;
            };
            const entry = &self.entries[index];
            @memcpy(entry.name[0..name.len], name);
            entry.name_len = name.len;
            @memcpy(entry.value[0..value.len], value);
            entry.value_len = value.len;
        }
    }
};

const max_stream_documents = 32;
const StreamSequence = struct {
    known: bool = false,
    parts: [max_stream_documents]syntax.InputPart = undefined,
    len: usize = 0,

    fn single(part: syntax.InputPart) StreamSequence {
        var sequence: StreamSequence = .{};
        if (part != .unknown) {
            sequence.known = true;
            sequence.parts[0] = part;
            sequence.len = 1;
        }
        return sequence;
    }

    fn append(self: *StreamSequence, part: syntax.InputPart) void {
        if (!self.known) return;
        if (part == .unknown or self.len == self.parts.len) {
            self.known = false;
            return;
        }
        self.parts[self.len] = part;
        self.len += 1;
    }

    fn eql(self: *const StreamSequence, other: *const StreamSequence) bool {
        if (self.known != other.known or self.len != other.len) return false;
        if (!self.known) return true;
        for (self.parts[0..self.len], other.parts[0..other.len]) |a, b| {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                .unknown => return false,
                .literal => |value| if (value.ptr != b.literal.ptr or value.len != b.literal.len) return false,
                .document => |doc| {
                    const other_doc = b.document;
                    if (doc.body.ptr != other_doc.body.ptr or doc.body.len != other_doc.body.len or doc.quoted != other_doc.quoted or doc.strip_tabs != other_doc.strip_tabs) return false;
                },
            }
        }
        return true;
    }
};

const InputStream = struct { replaced: StreamSequence = .{}, combined: StreamSequence = .{} };

/// Bash replaces stdin with each redirection; Zsh MULTIOS can concatenate
/// those inputs with one another and with a preceding pipeline.
fn resolveInput(input: syntax.Input, previous: InputStream) InputStream {
    var result: InputStream = if (input.pipeline == .stdout) previous else .{};
    for (input.redirections, 0..) |part, index| {
        result.replaced = StreamSequence.single(part);
        if (index == 0 and input.pipeline == .none) {
            result.combined = StreamSequence.single(part);
        } else {
            result.combined.append(part);
        }
    }
    return result;
}

/// Only a plain cat reading standard input preserves the known byte stream.
/// Other commands and redirected output leave the next stage unknown.
fn isTransparentCat(words: []const syntax.Word, path_may_change: bool) bool {
    var index: usize = 0;
    while (index < words.len and words[index].assignment) : (index += 1) {
        if (std.mem.startsWith(u8, words[index].text, "PATH=")) return false;
    }
    if (index == words.len or words[index].dynamic or
        !isOneOf(words[index].text, &.{ "cat", "/bin/cat", "/usr/bin/cat" })) return false;
    if (path_may_change and std.mem.eql(u8, words[index].text, "cat")) return false;
    index += 1;
    var end_options = false;
    while (index < words.len) : (index += 1) {
        if (words[index].dynamic) return false;
        if (!end_options and std.mem.eql(u8, words[index].text, "--")) {
            end_options = true;
        } else if (!std.mem.eql(u8, words[index].text, "-")) return false;
    }
    return true;
}

fn mayChangeLookup(words: []const syntax.Word) bool {
    var index: usize = 0;
    while (index < words.len and words[index].assignment) : (index += 1) {
        if (std.mem.startsWith(u8, words[index].text, "PATH=")) return true;
    }
    if (index == words.len or words[index].dynamic) return false;
    const name = words[index].text;
    if (isOneOf(name, &.{ "eval", "hash", "rehash", "cd", "pushd", "popd" })) return true;
    if (!isOneOf(name, &.{ "export", "unset", "read", "readonly", "local", "declare", "typeset" })) return false;
    for (words[index + 1 ..]) |word| if (word.dynamic or std.mem.eql(u8, word.text, "PATH") or std.mem.startsWith(u8, word.text, "PATH=")) return true;
    return false;
}

const Wrapper = enum { command, sudo, doas, env, exec, nohup, builtin, time, xargs };

fn isOneOf(value: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

/// Interpret complete words, independently of shell tokenization. Wrappers
/// are followed only when their option arity is known. A command lookup is a
/// separate operation from executing the named command.
fn classifyCommandContext(command: syntax.Command, input: *const InputStream, depth: u8, in_external_context: bool, inspect_interpreters: bool, comments: bool, context: Context) Risk {
    const words = command.words;
    var index: usize = 0;
    var external_context = in_external_context;
    var risk: Risk = .ordinary;
    while (index < words.len) {
        const value = words[index];
        if (context.live_variables and !external_context and value.session_assignment) {
            risk = .uncertain;
            index += 1;
            continue;
        }
        if (value.assignment) {
            index += 1;
            continue;
        }
        if (value.dynamic or value.tilde) return .uncertain;
        const name = std.fs.path.basename(value.text);
        // Control words precede the next command in a shell list.
        if (value.reserved and isOneOf(value.text, &.{ "if", "then", "elif", "else", "while", "until", "do", "!", "coproc", "noglob", "nocorrect" })) {
            if (context.live_variables and std.mem.eql(u8, value.text, "coproc")) risk = .uncertain;
            index += 1;
            continue;
        }
        if (context.live_variables and value.reserved and isOneOf(value.text, &.{ "for", "select" }) and index + 1 < words.len and !std.mem.eql(u8, words[index + 1].text, "((...))")) return .uncertain;
        if (value.reserved and std.mem.eql(u8, value.text, "repeat")) {
            if (index + 1 >= words.len or depth >= 7) return .uncertain;
            const count = words[index + 1];
            const count_risk = if (count.dynamic) Risk.uncertain else inspectEvaluatedExpression(count.text, depth, inspect_interpreters, comments);
            if (index + 2 == words.len) return combine(risk, count_risk);
            var remainder = command;
            remainder.words = words[index + 2 ..];
            return combine(combine(risk, count_risk), classifyCommandContext(remainder, input, depth + 1, external_context, inspect_interpreters, comments, context));
        }
        if (std.meta.stringToEnum(Wrapper, name)) |kind| {
            var replacement: ?[]const u8 = null;
            external_context = external_context or isOneOf(name, &.{ "sudo", "doas", "env", "exec", "nohup", "xargs" });
            index += 1;
            while (index < words.len) {
                const option = words[index];
                if (kind == .env and option.assignment) {
                    index += 1;
                    continue;
                }
                if (option.dynamic) return .uncertain;
                if (!std.mem.startsWith(u8, option.text, "-") or std.mem.eql(u8, option.text, "-")) break;
                if (std.mem.eql(u8, option.text, "--")) {
                    index += 1;
                    break;
                }
                if (kind == .command) {
                    if (commandOptions(option.text)) |is_lookup| {
                        // Once -v/-V is present the rest are lookup operands;
                        // their nested substitutions were already inspected.
                        if (is_lookup) return if (external_context or !std.mem.eql(u8, value.text, "command")) .uncertain else risk;
                        index += 1;
                        continue;
                    }
                }
                if ((kind == .sudo or kind == .doas or kind == .env) and isOneOf(option.text, &.{ "-u", "-g", "--user", "--group" })) {
                    index += 1;
                    if (index == words.len) return .uncertain;
                    index += 1;
                    continue;
                }
                if ((kind == .sudo or kind == .doas or kind == .env) and isOneOf(option.text, &.{ "-n", "-i" })) {
                    index += 1;
                    continue;
                }
                if (kind == .xargs) {
                    switch (xargsOption(option.text)) {
                        .flag => {
                            if (xargsReplacement(option.text)) |placeholder| replacement = placeholder;
                            index += 1;
                            continue;
                        },
                        .argument => {
                            index += 1;
                            if (index == words.len) return .uncertain;
                            if (xargsReplacementArgument(option.text)) {
                                if (words[index].dynamic) return .uncertain;
                                replacement = words[index].text;
                            }
                            index += 1;
                            continue;
                        },
                        .unknown => return .uncertain,
                    }
                }
                return .uncertain;
            }
            if (kind == .xargs and index < words.len) {
                return combine(risk, classifyXargs(words[index..], command, replacement, depth, inspect_interpreters, comments));
            }
            continue;
        }
        if (std.mem.startsWith(u8, name, "mkfs") or std.mem.startsWith(u8, name, "shutdown")) return .blocked;
        index += 1;
        return combine(risk, classifyExecutable(value, words[index..], command, input, depth, external_context, inspect_interpreters, comments, context));
    }
    return risk;
}

fn classifyExecutable(value: syntax.Word, args: []const syntax.Word, command: syntax.Command, input: *const InputStream, depth: u8, external_context: bool, inspect_interpreters: bool, comments: bool, context: Context) Risk {
    const name = std.fs.path.basename(value.text);
    if (std.mem.eql(u8, name, "rm")) return classifyRemove(args);
    if (std.mem.eql(u8, name, "alias")) return classifyAlias(args, depth, inspect_interpreters, comments);
    if (std.mem.eql(u8, name, "function")) return .uncertain;
    if (std.mem.eql(u8, name, "eval")) return classifyEval(args, depth, inspect_interpreters, context);
    if (!external_context and std.mem.eql(u8, value.text, "trap")) return classifyTrap(args, depth, inspect_interpreters, context);
    if (!external_context and std.mem.eql(u8, value.text, name)) {
        if (classifyVariableBuiltin(name, args, depth, inspect_interpreters, comments, context)) |risk| return risk;
    }
    if (isOneOf(name, &.{ "source", "." })) return .uncertain;
    if (isOneOf(name, &.{ "sh", "bash", "zsh", "dash", "ksh" })) {
        // A bare shell name can resolve to a function in the live session.
        const child_context: Context = if (!external_context and std.mem.eql(u8, value.text, name)) context else .{};
        return classifyShell(args, command.has_process_substitution, input, depth, inspect_interpreters, child_context);
    }
    if (isInputInterpreter(name)) {
        return switch (interpreterInput(args)) {
            .harmless => .ordinary,
            .external => if (inspect_interpreters) .uncertain else .ordinary,
            .unknown => .uncertain,
            .stdin => if (std.mem.startsWith(u8, name, "python")) inspectPythonInput(input, depth) else .uncertain,
            .inline_script => |script| if (!inspect_interpreters) .ordinary else if (std.mem.startsWith(u8, name, "python")) inspectPythonScript(script, depth) else .uncertain,
        };
    }
    return .ordinary;
}

const Option = enum { flag, argument, unknown };

/// xargs either appends input words or substitutes them into its arguments.
/// Propagate that unknown input through the existing command policy instead
/// of treating a placeholder as a literal command, script, or removal target.
fn classifyXargs(words: []const syntax.Word, command: syntax.Command, replacement: ?[]const u8, depth: u8, inspect_interpreters: bool, comments: bool) Risk {
    if (depth >= 7 or words.len >= 513) return .uncertain;
    var expanded: [513]syntax.Word = undefined;
    for (words, 0..) |word, i| {
        expanded[i] = word;
        if (replacement) |placeholder| {
            if (placeholder.len == 0) return .uncertain;
            if (std.mem.indexOf(u8, word.text, placeholder) != null) expanded[i].dynamic = true;
        }
    }
    var count = words.len;
    if (replacement == null) {
        expanded[count] = .{ .text = "", .dynamic = true };
        count += 1;
    }
    const unknown: InputStream = .{};
    return classifyCommandContext(.{
        .words = expanded[0..count],
        .has_here_document = command.has_here_document,
        .has_process_substitution = command.has_process_substitution,
    }, &unknown, depth + 1, true, inspect_interpreters, comments, .{});
}

fn xargsReplacement(option: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, option, "--replace")) return "{}";
    if (std.mem.startsWith(u8, option, "--replace=")) return option["--replace=".len..];
    if (option.len < 2 or option[0] != '-' or option[1] == '-') return null;
    for (option[1..], 1..) |c, i| {
        if (std.mem.indexOfScalar(u8, "0rtpo", c) != null) continue;
        if (c == 'I' and i + 1 < option.len) return option[i + 1 ..];
        break;
    }
    return null;
}

fn xargsReplacementArgument(option: []const u8) bool {
    if (option.len < 2 or option[0] != '-' or option[1] == '-') return false;
    for (option[1..], 1..) |c, i| {
        if (std.mem.indexOfScalar(u8, "0rtpo", c) != null) continue;
        return c == 'I' and i + 1 == option.len;
    }
    return false;
}

fn xargsOption(option: []const u8) Option {
    const flags: []const []const u8 = &.{ "--null", "--no-run-if-empty", "--verbose", "--interactive", "--open-tty", "--replace", "--eof", "--max-lines" };
    const long_values: []const []const u8 = &.{ "--max-args", "--max-procs", "--replace", "--max-lines", "--max-chars", "--eof", "--delimiter", "--arg-file" };
    if (isOneOf(option, flags)) return .flag;
    if (isOneOf(option, &.{ "--max-args", "--max-procs", "--max-chars", "--delimiter", "--arg-file" })) return .argument;
    for (long_values) |prefix| if (std.mem.startsWith(u8, option, prefix) and option.len > prefix.len and option[prefix.len] == '=') return .flag;
    if (option.len > 1 and option[0] == '-' and option[1] != '-') {
        for (option[1..], 1..) |c, i| {
            if (std.mem.indexOfScalar(u8, "0rtpo", c) != null) continue;
            if (std.mem.indexOfScalar(u8, "nPILsEda", c) != null) return if (i + 1 < option.len) .flag else .argument;
            return .unknown;
        }
        return .flag;
    }
    return .unknown;
}

/// These runtimes interpret standard input as program text when no script or
/// inline program is supplied. Other external program effects are outside the
/// shell grammar and retain the existing full-control semantics.
fn isInputInterpreter(name: []const u8) bool {
    if (isOneOf(name, &.{ "python", "node", "nodejs", "perl", "ruby", "php", "lua" })) return true;
    for ([_][]const u8{ "python", "perl", "lua" }) |prefix| {
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) continue;
        var versioned = true;
        for (name[prefix.len..]) |c| {
            if (!std.ascii.isDigit(c) and c != '.') {
                versioned = false;
                break;
            }
        }
        if (versioned) return true;
    }
    return false;
}

const InterpreterInput = union(enum) { stdin, inline_script: []const u8, external, harmless, unknown };

fn interpreterInput(words: []const syntax.Word) InterpreterInput {
    var index: usize = 0;
    while (index < words.len) : (index += 1) {
        const value = words[index];
        if (value.dynamic) return .unknown;
        const text = value.text;
        if (std.mem.eql(u8, text, "-")) return .stdin;
        if (std.mem.eql(u8, text, "--")) {
            index += 1;
            if (index == words.len or std.mem.eql(u8, words[index].text, "-")) return .stdin;
            return if (words[index].dynamic) .unknown else .external;
        }
        if (!std.mem.startsWith(u8, text, "-")) return .external;
        if (isOneOf(text, &.{ "-c", "-e", "--eval" })) {
            return if (index + 1 == words.len or words[index + 1].dynamic) .unknown else .{ .inline_script = words[index + 1].text };
        }
        if (std.mem.eql(u8, text, "-m")) return if (index + 1 == words.len or words[index + 1].dynamic) .unknown else .external;
        if (isOneOf(text, &.{ "-V", "--version", "-h", "--help" })) return .harmless;
        if (!isOneOf(text, &.{ "-u", "-i", "-B", "-E", "-s", "-S", "-O", "-OO", "-q", "-I" })) return .unknown;
    }
    return .stdin;
}

/// `command -p` selects a search path; `-v` and `-V` query rather than execute.
fn commandOptions(option: []const u8) ?bool {
    if (option.len < 2 or option[0] != '-' or option[1] == '-') return null;
    var lookup = false;
    for (option[1..]) |c| switch (c) {
        'p' => {},
        'v', 'V' => lookup = true,
        else => return null,
    };
    return lookup;
}

fn classifyRemove(words: []const syntax.Word) Risk {
    var recursive = false;
    var force = false;
    var absolute = false;
    var flags = true;
    var result: Risk = .ordinary;
    for (words) |value| {
        if (value.dynamic) {
            result = .uncertain;
            // A literal absolute prefix remains absolute after expansion.
            absolute = absolute or value.tilde or std.fs.path.isAbsolute(value.text);
            continue;
        }
        const text = value.text;
        if (flags and std.mem.eql(u8, text, "--")) {
            flags = false;
        } else if (flags and std.mem.eql(u8, text, "--recursive")) {
            recursive = true;
        } else if (flags and std.mem.eql(u8, text, "--force")) {
            force = true;
        } else if (flags and text.len > 1 and text[0] == '-' and text[1] != '-') {
            recursive = recursive or std.mem.indexOfAny(u8, text[1..], "rR") != null;
            force = force or std.mem.indexOfScalar(u8, text[1..], 'f') != null;
        } else {
            absolute = absolute or value.tilde or std.fs.path.isAbsolute(text);
        }
    }
    return if (recursive and force and absolute) .blocked else result;
}

fn classifyAlias(words: []const syntax.Word, depth: u8, inspect_interpreters: bool, comments: bool) Risk {
    var result: Risk = .uncertain;
    for (words) |word| {
        if (!word.assignment or word.dynamic) continue;
        const equal = std.mem.indexOfScalar(u8, word.text, '=') orelse continue;
        result = combine(result, inspectCommentMode(word.text[equal + 1 ..], depth + 1, inspect_interpreters, comments, .{}));
    }
    return result;
}

fn classifyTrap(words: []const syntax.Word, depth: u8, inspect_interpreters: bool, context: Context) Risk {
    if (words.len == 0) return .ordinary;
    var index: usize = 0;
    if (words[index].dynamic) return .uncertain;
    if (std.mem.eql(u8, words[index].text, "--")) {
        index += 1;
    } else if (isOneOf(words[index].text, &.{ "-p", "-l" })) {
        return .ordinary;
    } else if (std.mem.startsWith(u8, words[index].text, "-") and !std.mem.eql(u8, words[index].text, "-")) {
        return .uncertain;
    }
    if (index >= words.len or words[index].dynamic) return .uncertain;
    if (std.mem.eql(u8, words[index].text, "-") or index + 1 == words.len) return .ordinary;
    return inspectCommentMode(words[index].text, depth + 1, inspect_interpreters, true, context);
}

const ExpressionAnalysis = struct {
    depth: u8,
    inspect_interpreters: bool,
    comments: bool,
    risk: Risk = .ordinary,

    fn command(_: *anyopaque, _: syntax.Command) void {}

    fn nested(raw: *anyopaque, script: []const u8, depth: u8) void {
        const self: *ExpressionAnalysis = @ptrCast(@alignCast(raw));
        self.risk = combine(self.risk, inspectCommentMode(script, depth, self.inspect_interpreters, self.comments, .{}));
    }

    fn arithmetic(raw: *anyopaque, expression: []const u8, depth: u8) void {
        const self: *ExpressionAnalysis = @ptrCast(@alignCast(raw));
        self.risk = combine(self.risk, inspectEvaluatedExpression(expression, depth, self.inspect_interpreters, self.comments));
    }
};

fn inspectPromptValue(value: []const u8, depth: u8, inspect_interpreters: bool, comments: bool) Risk {
    var analysis: ExpressionAnalysis = .{ .depth = depth, .inspect_interpreters = inspect_interpreters, .comments = comments };
    const complete = syntax.inspectPrompt(value, depth + 1, .{
        .context = &analysis,
        .command = ExpressionAnalysis.command,
        .nested = ExpressionAnalysis.nested,
        .arithmetic = ExpressionAnalysis.arithmetic,
    }, comments);
    return combine(analysis.risk, if (complete) .ordinary else .uncertain);
}

/// Shell arithmetic and array subscripts can evaluate substitutions even
/// when the containing argument was quoted. Variable-dependent arithmetic
/// stays uncertain because its runtime value may itself contain an expression.
fn inspectEvaluatedExpression(expression: []const u8, depth: u8, inspect_interpreters: bool, comments: bool) Risk {
    var uncertain = false;
    var nested = false;
    for (expression) |c| {
        if (std.ascii.isAlphabetic(c) or c == '_' or c >= 128 or c == '\'' or c == '"') uncertain = true;
        if (c == '$' or c == '`') {
            uncertain = true;
            nested = true;
        }
    }
    var analysis: ExpressionAnalysis = .{ .depth = depth, .inspect_interpreters = inspect_interpreters, .comments = comments };
    if (nested) {
        const complete = syntax.parse(expression, depth + 1, .{
            .context = &analysis,
            .command = ExpressionAnalysis.command,
            .nested = ExpressionAnalysis.nested,
            .arithmetic = ExpressionAnalysis.arithmetic,
        }, comments);
        if (!complete) uncertain = true;
    }
    return combine(analysis.risk, if (uncertain) .uncertain else .ordinary);
}

fn inspectVariableTarget(value: syntax.Word, depth: u8, inspect_interpreters: bool, comments: bool) Risk {
    const text = value.text;
    var at: usize = 0;
    if (text.len != 0 and (std.ascii.isAlphabetic(text[0]) or text[0] == '_')) {
        at = 1;
        while (at < text.len and (std.ascii.isAlphanumeric(text[at]) or text[at] == '_')) at += 1;
    }
    if (at == 0 or at == text.len or text[at] != '[') return if (value.dynamic and !value.assignment) .uncertain else .ordinary;
    const start = at + 1;
    var nesting: usize = 1;
    at = start;
    while (at < text.len) : (at += 1) {
        if (text[at] == '[') nesting += 1;
        if (text[at] == ']') {
            nesting -= 1;
            if (nesting == 0) {
                return combine(if (value.dynamic) .uncertain else .ordinary, inspectEvaluatedExpression(text[start..at], depth, inspect_interpreters, comments));
            }
        }
    }
    return .uncertain;
}

const VariableDeclaration = struct { name: []const u8, initializer: ?[]const u8 };

fn variableDeclaration(text: []const u8) ?VariableDeclaration {
    if (text.len == 0 or (!std.ascii.isAlphabetic(text[0]) and text[0] != '_')) return null;
    var at: usize = 1;
    while (at < text.len and (std.ascii.isAlphanumeric(text[at]) or text[at] == '_')) at += 1;
    const name = text[0..at];
    if (at < text.len and text[at] == '[') {
        var nesting: usize = 1;
        at += 1;
        while (at < text.len and nesting != 0) : (at += 1) {
            if (text[at] == '[') nesting += 1;
            if (text[at] == ']') nesting -= 1;
        }
        if (nesting != 0) return null;
    }
    if (at == text.len) return .{ .name = name, .initializer = null };
    if (text[at] != '=') return null;
    return .{ .name = name, .initializer = text[at + 1 ..] };
}

/// Attributes set by a visible declaration can make later assignments
/// evaluate arithmetic instead of storing literal text.
const NumericVariables = struct {
    names: [64][128]u8 = undefined,
    lengths: [64]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,

    fn contains(self: *const NumericVariables, name: []const u8) bool {
        for (0..self.len) |index| if (std.mem.eql(u8, self.names[index][0..self.lengths[index]], name)) return true;
        return false;
    }

    fn add(self: *NumericVariables, name: []const u8) void {
        if (self.contains(name)) return;
        if (name.len > self.names[0].len or self.len == self.names.len) {
            self.overflow = true;
            return;
        }
        @memcpy(self.names[self.len][0..name.len], name);
        self.lengths[self.len] = @intCast(name.len);
        self.len += 1;
    }

    fn initializerRisk(self: *const NumericVariables, word: syntax.Word, force: bool, depth: u8, inspect_interpreters: bool, comments: bool) Risk {
        const declaration = variableDeclaration(word.text) orelse return if (self.overflow and word.dynamic) .uncertain else .ordinary;
        const initializer = declaration.initializer orelse return .ordinary;
        if (!force and !self.contains(declaration.name)) return if (self.overflow) .uncertain else .ordinary;
        return if (word.dynamic) .uncertain else inspectEvaluatedExpression(initializer, depth, inspect_interpreters, comments);
    }

    fn inspect(self: *NumericVariables, words: []const syntax.Word, depth: u8, inspect_interpreters: bool, comments: bool) Risk {
        var risk: Risk = .ordinary;
        var index: usize = 0;
        while (index < words.len) {
            const word = words[index];
            if (word.assignment) {
                risk = combine(risk, self.initializerRisk(word, false, depth, inspect_interpreters, comments));
                index += 1;
            } else if (word.reserved and isOneOf(word.text, &.{ "if", "then", "elif", "else", "while", "until", "do", "!", "noglob", "nocorrect" })) {
                index += 1;
            } else if (std.mem.eql(u8, word.text, "builtin") or std.mem.eql(u8, word.text, "command")) {
                index += 1;
                while (index < words.len and isOneOf(words[index].text, &.{ "--", "-p" })) : (index += 1) {}
            } else break;
        }
        if (index == words.len or words[index].dynamic) return risk;
        const name = words[index].text;
        if (!isOneOf(name, &.{ "declare", "typeset", "local", "readonly", "export", "integer", "float" })) return risk;
        var numeric = isOneOf(name, &.{ "integer", "float" });
        var query = false;
        index += 1;
        while (index < words.len and std.mem.startsWith(u8, words[index].text, "-")) : (index += 1) {
            const option = words[index];
            if (option.dynamic) return combine(risk, .uncertain);
            if (std.mem.eql(u8, option.text, "--")) {
                index += 1;
                break;
            }
            numeric = numeric or std.mem.indexOfAny(u8, option.text[1..], "iEF") != null;
            query = query or std.mem.indexOfScalar(u8, option.text[1..], 'p') != null;
        }
        if (query) return risk;
        while (index < words.len) : (index += 1) {
            const word = words[index];
            if (numeric) {
                if (word.dynamic and !word.assignment) {
                    self.overflow = true;
                    risk = combine(risk, .uncertain);
                } else if (variableDeclaration(word.text)) |declaration| {
                    self.add(declaration.name);
                }
            }
            risk = combine(risk, self.initializerRisk(word, numeric, depth, inspect_interpreters, comments));
        }
        return risk;
    }
};

fn printfMayWriteVariable(format: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, format, at, '%')) |percent| {
        at = percent + 1;
        while (at < format.len and std.mem.indexOfScalar(u8, "#0- +'.*123456789", format[at]) != null) at += 1;
        if (at == format.len) break;
        if (format[at] == 'n') return true;
        at += 1;
    }
    return false;
}

fn classifyVariableBuiltin(name: []const u8, words: []const syntax.Word, depth: u8, inspect_interpreters: bool, comments: bool, context: Context) ?Risk {
    const variable_risk: Risk = if (context.live_variables) .uncertain else .ordinary;
    if (std.mem.eql(u8, name, "getopts")) {
        if (words.len < 2) return .ordinary;
        return combine(variable_risk, inspectVariableTarget(words[1], depth, inspect_interpreters, comments));
    }
    if (std.mem.eql(u8, name, "let")) {
        var risk: Risk = .ordinary;
        for (words) |word| {
            risk = combine(risk, if (word.dynamic) .uncertain else inspectEvaluatedExpression(word.text, depth, inspect_interpreters, comments));
        }
        return risk;
    }
    if (std.mem.eql(u8, name, "printf")) {
        var index: usize = 0;
        while (index < words.len) : (index += 1) {
            const option = words[index];
            if (option.dynamic) return .uncertain;
            if (std.mem.eql(u8, option.text, "--") or !std.mem.startsWith(u8, option.text, "-")) break;
            if (std.mem.eql(u8, option.text, "-v")) {
                if (index + 1 == words.len) return .uncertain;
                return combine(variable_risk, inspectVariableTarget(words[index + 1], depth, inspect_interpreters, comments));
            }
            if (std.mem.startsWith(u8, option.text, "-v") and option.text.len > 2) {
                var target = option;
                target.text = option.text[2..];
                return combine(variable_risk, inspectVariableTarget(target, depth, inspect_interpreters, comments));
            }
        }
        if (index < words.len and std.mem.eql(u8, words[index].text, "--")) index += 1;
        if (context.live_variables and index < words.len and (words[index].dynamic or printfMayWriteVariable(words[index].text))) return .uncertain;
        return .ordinary;
    }
    if (context.live_variables and isOneOf(name, &.{ "mapfile", "readarray" })) return .uncertain;
    if (context.live_variables and isOneOf(name, &.{ "[[", "[", "test" })) {
        for (words) |word| {
            if (isOneOf(word.text, &.{ "-v", "-R" }) or
                (std.mem.eql(u8, name, "[[") and isOneOf(word.text, &.{ "-eq", "-ne", "-lt", "-le", "-gt", "-ge" }))) return .uncertain;
        }
    }
    if (!isOneOf(name, &.{ "unset", "read", "declare", "typeset", "local", "export", "readonly", "integer", "float" })) return null;
    var query = words.len == 1 and std.mem.eql(u8, words[0].text, "-p") and isOneOf(name, &.{ "export", "readonly" });
    if (isOneOf(name, &.{ "declare", "typeset", "local" })) {
        var nameref = false;
        var index: usize = 0;
        while (index < words.len) : (index += 1) {
            const option = words[index];
            if (option.dynamic) return .uncertain;
            if (std.mem.eql(u8, option.text, "--")) {
                index += 1;
                break;
            }
            if (option.text.len < 2 or option.text[0] != '-') break;
            nameref = nameref or std.mem.indexOfScalar(u8, option.text[1..], 'n') != null;
            query = query or std.mem.indexOfScalar(u8, option.text[1..], 'p') != null;
        }
        // A nameref can defer evaluation of an array subscript until a later
        // read or assignment. Creating one does not itself execute it.
        if (nameref and !query and index < words.len) return .uncertain;
    }
    if (std.mem.eql(u8, name, "unset")) {
        var function_only = false;
        var variable_mode = false;
        for (words) |word| {
            if (std.mem.eql(u8, word.text, "--") or !std.mem.startsWith(u8, word.text, "-")) break;
            if (std.mem.eql(u8, word.text, "-f")) function_only = true;
            if (std.mem.eql(u8, word.text, "-v")) variable_mode = true;
        }
        if (function_only and !variable_mode) return .ordinary;
    }
    var risk: Risk = if (std.mem.eql(u8, name, "read") or (words.len != 0 and !query)) variable_risk else .ordinary;
    for (words) |word| risk = combine(risk, inspectVariableTarget(word, depth, inspect_interpreters, comments));
    return risk;
}

fn classifyShell(words: []const syntax.Word, has_process_substitution: bool, input: *const InputStream, depth: u8, inspect_interpreters: bool, context: Context) Risk {
    const input_risk: Risk = if (has_process_substitution) .uncertain else .ordinary;
    var index: usize = 0;
    var reads_stdin = false;
    var interactive = false;
    while (index < words.len) : (index += 1) {
        const value = words[index];
        if (value.dynamic) return .uncertain;
        const text = value.text;
        if (isOneOf(text, &.{ "-o", "-O", "--rcfile", "--init-file" })) {
            index += 1;
            if (index == words.len) return .uncertain;
            if (words[index].dynamic) return .uncertain;
            if (isOneOf(words[index].text, &.{ "interactive", "INTERACTIVE" })) interactive = true;
        } else if (std.mem.eql(u8, text, "--")) {
            if (!reads_stdin and index + 1 < words.len and !std.mem.eql(u8, words[index + 1].text, "-")) return .uncertain;
            return combine(input_risk, inspectShellInput(input, depth, interactive, context));
        } else if (std.mem.startsWith(u8, text, "--")) {
            if (!isOneOf(text, &.{ "--noprofile", "--norc", "--posix" })) return .uncertain;
        } else if (text.len > 1 and text[0] == '-') {
            interactive = interactive or std.mem.indexOfScalar(u8, text[1..], 'i') != null;
            if (std.mem.indexOfScalar(u8, text[1..], 'c') != null) {
                index += 1;
                if (index == words.len or words[index].dynamic) return .uncertain;
                return combine(input_risk, inspectCommentMode(words[index].text, depth + 1, inspect_interpreters, true, context));
            }
            reads_stdin = reads_stdin or std.mem.indexOfScalar(u8, text[1..], 's') != null;
        } else {
            if (reads_stdin or std.mem.eql(u8, text, "-")) return combine(input_risk, inspectShellInput(input, depth, interactive, context));
            // The content of an external script is not present in this call.
            return .uncertain;
        }
    }
    // A shell with neither -c nor a script reads commands from its input.
    return combine(input_risk, inspectShellInput(input, depth, interactive, context));
}

const ScriptLanguage = union(enum) { shell: struct { interactive: bool, context: Context }, python };

fn inspectSequence(sequence: *const StreamSequence, depth: u8, language: ScriptLanguage) Risk {
    if (!sequence.known) return .uncertain;
    var size: usize = 0;
    for (sequence.parts[0..sequence.len]) |part| {
        const part_size = switch (part) {
            .unknown => return .uncertain,
            .document => |document| document.body.len,
            .literal => |value| value.len + 1,
        };
        if (part_size > 65534 - size) return .uncertain;
        size += part_size;
    }
    const buffer = std.heap.page_allocator.alloc(u8, size) catch return .uncertain;
    defer std.heap.page_allocator.free(buffer);
    var used: usize = 0;
    for (sequence.parts[0..sequence.len]) |part| {
        switch (part) {
            .unknown => return .uncertain,
            .document => |document| {
                const literal = syntax.literalDocument(document, buffer[used..]) orelse return .uncertain;
                used += literal.len;
            },
            .literal => |value| {
                @memcpy(buffer[used..][0..value.len], value);
                used += value.len;
                buffer[used] = '\n';
                used += 1;
            },
        }
    }
    return switch (language) {
        .shell => |shell| if (shell.interactive)
            inspectWithContext(buffer[0..used], depth + 1, true, shell.context)
        else
            inspectCommentMode(buffer[0..used], depth + 1, true, true, shell.context),
        .python => inspectPythonScript(buffer[0..used], depth),
    };
}

fn inspectInput(input: *const InputStream, depth: u8, language: ScriptLanguage) Risk {
    const replaced = inspectSequence(&input.replaced, depth, language);
    if (input.replaced.eql(&input.combined)) return replaced;
    return combine(replaced, inspectSequence(&input.combined, depth, language));
}

fn inspectShellInput(input: *const InputStream, depth: u8, interactive: bool, context: Context) Risk {
    return inspectInput(input, depth, .{ .shell = .{ .interactive = interactive, .context = context } });
}

const PythonContext = struct {
    depth: u8,

    fn shell(raw: *anyopaque, script: []const u8) Risk {
        const self: *PythonContext = @ptrCast(@alignCast(raw));
        return inspectCommentMode(script, self.depth + 1, true, true, .{});
    }

    fn argv(raw: *anyopaque, values: []const []const u8) Risk {
        const self: *PythonContext = @ptrCast(@alignCast(raw));
        if (values.len == 0 or values.len > 64) return .uncertain;
        var words: [64]syntax.Word = undefined;
        for (values, 0..) |value, index| words[index] = .{
            .text = value,
            .assignment = index != 0 and isAssignment(value),
        };
        const unknown: InputStream = .{};
        return classifyCommandContext(.{
            .words = words[0..values.len],
            .has_here_document = false,
            .has_process_substitution = false,
        }, &unknown, self.depth + 1, false, true, true, .{});
    }
};

fn isAssignment(value: []const u8) bool {
    const equal = std.mem.indexOfScalar(u8, value, '=') orelse return false;
    if (equal == 0 or (!std.ascii.isAlphabetic(value[0]) and value[0] != '_')) return false;
    for (value[0..equal]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn inspectPythonInput(input: *const InputStream, depth: u8) Risk {
    return if (depth >= 7) .uncertain else inspectInput(input, depth, .python);
}

fn inspectPythonScript(script: []const u8, depth: u8) Risk {
    if (depth >= 7) return .uncertain;
    var context: PythonContext = .{ .depth = depth };
    return python.inspect(script, .{ .context = &context, .shell = PythonContext.shell, .argv = PythonContext.argv });
}

fn classifyEval(words: []const syntax.Word, depth: u8, inspect_interpreters: bool, context: Context) Risk {
    var script: [16384]u8 = undefined;
    var len: usize = 0;
    const arguments = if (words.len != 0 and !words[0].dynamic and std.mem.eql(u8, words[0].text, "--")) words[1..] else words;
    for (arguments) |value| {
        if (value.dynamic or value.text.len + 1 > script.len - len) return .uncertain;
        if (len != 0) {
            script[len] = ' ';
            len += 1;
        }
        @memcpy(script[len..][0..value.text.len], value.text);
        len += value.text.len;
    }
    return if (context.live_variables)
        inspectWithContext(script[0..len], depth + 1, inspect_interpreters, context)
    else
        inspectCommentMode(script[0..len], depth + 1, inspect_interpreters, true, context);
}
