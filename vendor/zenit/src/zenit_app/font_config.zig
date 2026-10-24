//! Font configuration shared by native App runtimes.
pub const FontConfig = struct {
    /// BCP-47 language for Windows DirectWrite fallback (for example zh-CN or ja-JP).
    locale: [:0]const u8 = "en-us",
    /// Default font size (for ui.text default 14pt). `small` slot.
    small_size: u32 = 14,
    /// Medium font (for H3 etc). `medium` slot.
    medium_size: u32 = 18,
    /// Large font (for H2 etc). `large` slot.
    large_size: u32 = 24,
    /// Font family fallback chain. First found wins. Default chain compatible with macOS / Linux
    /// desktop.
    fallback_families: []const []const u8 = if (@import("builtin").target.os.tag == .windows) &.{ "Segoe UI", "Arial", "Inter" } else &.{
        "Helvetica Neue",
        "Arial",
        "Helvetica",
        "Inter",
        "Menlo",
    },
};
