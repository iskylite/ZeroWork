//! BMC-specific probe warnings carried in the existing safe-message field.
//! Only these fixed texts are recognized; no device-provided text is retained.
const std = @import("std");
const progress = @import("connection_progress.zig");

pub const Warning = enum { discovery, identity, discovery_and_identity };

pub fn warningForSnapshot(snapshot: *const progress.Snapshot) ?Warning {
    if (snapshot.discovery_issue != null) return if (snapshot.identity_warning != null) .discovery_and_identity else .discovery;
    if (snapshot.identity_warning != null) return .identity;
    return null;
}

pub fn warningText(warning: Warning) []const u8 {
    return switch (warning) {
        .discovery => "管理登录已验证；资源发现不完整，部分管理功能可能不可用；未打开视频",
        .identity => "管理连接已验证；未识别公开设备型号；未打开视频",
        .discovery_and_identity => "管理登录已验证；资源发现不完整，部分管理功能可能不可用；未识别公开设备型号；未打开视频",
    };
}

/// Provider appends only timing and cleanup information to the fixed text.
pub fn warningFromMessage(message: []const u8) ?Warning {
    inline for (std.enums.values(Warning)) |warning| {
        const text = warningText(warning);
        if (std.mem.eql(u8, message, text) or
            (std.mem.startsWith(u8, message, text) and std.mem.startsWith(u8, message[text.len..], " · 总计 "))) return warning;
    }
    return null;
}
