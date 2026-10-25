//! Standalone composite-document suite; avoids filtered UI aggregator imports.
comptime {
    _ = @import("ui/terminal_document.zig");
    _ = @import("ui/history_cast.zig");
}
