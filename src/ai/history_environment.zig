const std = @import("std");

pub const marker = "[历史环境，仅作记录]";

/// Remove model-context markers echoed at the start of assistant prose.
/// Leave inline references, Markdown code, and the saved transcript intact.
pub fn assistantText(source: []const u8) []const u8 {
    var remaining = std.mem.trimStart(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, remaining, marker)) return source;
    while (std.mem.startsWith(u8, remaining, marker)) {
        const after = remaining[marker.len..];
        remaining = std.mem.trimStart(u8, after, " \t\r\n");
        if (std.mem.startsWith(u8, remaining, marker)) continue;
        // Preserve indentation on the first real line after a marker-only line.
        const line = std.mem.trimStart(u8, after, " \t\r");
        if (line.len > 0 and line[0] == '\n') return std.mem.trimStart(u8, line[1..], "\r\n");
    }
    return remaining;
}

test "assistant prose removes repeated history markers only at the start" {
    const eq = std.testing.expectEqualStrings;
    try eq("实际结果", assistantText(marker ++ " " ++ marker ++ "\n实际结果"));
    try eq("", assistantText(marker ++ "\n " ++ marker ++ "  "));
    try eq("    code", assistantText(marker ++ "\r\n    code"));
    try eq("正文 " ++ marker, assistantText("正文 " ++ marker));
    try eq("`" ++ marker ++ "`", assistantText("`" ++ marker ++ "`"));
}

/// Local/remote attachment wrappers are appended by the host, not portable
/// user instructions. Strip at the first wrapper even when a later suffix is
/// malformed, rather than copying retained source bytes to another context.
pub fn portableUserText(wire: []const u8) []const u8 {
    var end = wire.len;
    for ([_][]const u8{
        "\n\n<local_text_attachment>",         "\n\n<local_file_reference>",
        "\n\n<remote_file_attachment>",        "\n\n<remote_file_reference>",
        "\n\n<terminal_selection_attachment>", "\n@file: ",
    }) |prefix| if (std.mem.indexOf(u8, wire, prefix)) |i| {
        end = @min(end, i);
    };
    if (std.mem.startsWith(u8, wire, "@file: ")) return "";
    return wire[0..end];
}
