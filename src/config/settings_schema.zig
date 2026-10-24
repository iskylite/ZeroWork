//! The settings-page directory is the single list of editable scalar fields.
//! Composite key/provider editors participate in the same change set.
const std = @import("std");
const config = @import("config.zig");
const pages = @import("settings_pages.zig");

pub const fields = pages.keys;
pub const keys_index = fields.len;
pub const providers_index = fields.len + 1;
pub const plugin_preferences_index = fields.len + 2;
pub const field_count = fields.len + 3;
pub const FieldSet = std.StaticBitSet(field_count);

pub fn find(section: []const u8, key: []const u8) ?usize {
    for (fields, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.section, section) and std.mem.eql(u8, entry.key, key)) return index;
    }
    return null;
}

pub fn same(a: anytype, b: @TypeOf(a)) bool {
    switch (@typeInfo(@TypeOf(a))) {
        .@"struct" => |info| {
            inline for (info.field_names) |field| if (!same(@field(a, field), @field(b, field))) return false;
            return true;
        },
        .optional => {
            if (a) |value| return if (b) |other| same(value, other) else false;
            return b == null;
        },
        .array => {
            for (a, b) |left, right| if (!same(left, right)) return false;
            return true;
        },
        .pointer => |info| {
            if (info.size != .slice) return a == b;
            if (a.len != b.len) return false;
            for (a, b) |left, right| if (!same(left, right)) return false;
            return true;
        },
        else => return a == b,
    }
}

pub fn fieldEqual(a: config.Config, b: config.Config, index: usize) bool {
    if (index == plugin_preferences_index) return same(a.plugin_preferences, b.plugin_preferences);
    if (index == keys_index) return same(a.keys, b.keys);
    if (index == providers_index) return a.ai.provider_count == b.ai.provider_count and same(a.ai.providers, b.ai.providers);
    if (index >= fields.len) return false;
    const entry = fields[index];
    if (std.mem.eql(u8, entry.section, "ui.materials")) return same(a.ui.materials.blur_px, b.ui.materials.blur_px);
    if (std.mem.eql(u8, entry.section, "ui.materials.background")) {
        inline for (@typeInfo(config.material.Background).@"struct".field_names) |field| {
            if (std.mem.eql(u8, entry.key, field)) return same(@field(a.ui.materials.background, field), @field(b.ui.materials.background, field));
        }
        unreachable;
    }
    inline for (@typeInfo(config.Config).@"struct".field_names) |section| {
        const Section = @TypeOf(@field(a, section));
        if (@typeInfo(Section) == .@"struct") {
            if (std.mem.eql(u8, entry.section, section)) {
                inline for (@typeInfo(Section).@"struct".field_names) |field| {
                    if (std.mem.eql(u8, entry.key, field)) return same(@field(@field(a, section), field), @field(@field(b, section), field));
                }
            }
        }
    }
    unreachable;
}

/// Borrowed result: take an owned Snapshot before either source can change.
pub fn merge(latest: config.Config, draft: config.Config, dirty: FieldSet) config.Config {
    var result = latest;
    for (fields, 0..) |entry, index| {
        if (!dirty.isSet(index)) continue;
        if (std.mem.eql(u8, entry.section, "ui.materials")) {
            result.ui.materials.blur_px = draft.ui.materials.blur_px;
            continue;
        }
        if (std.mem.eql(u8, entry.section, "ui.materials.background")) {
            inline for (@typeInfo(config.material.Background).@"struct".field_names) |field| {
                if (std.mem.eql(u8, entry.key, field)) @field(result.ui.materials.background, field) = @field(draft.ui.materials.background, field);
            }
            continue;
        }
        inline for (@typeInfo(config.Config).@"struct".field_names) |section| {
            const Section = @TypeOf(@field(result, section));
            if (@typeInfo(Section) == .@"struct") {
                if (std.mem.eql(u8, entry.section, section)) {
                    inline for (@typeInfo(Section).@"struct".field_names) |field| {
                        if (std.mem.eql(u8, entry.key, field)) @field(@field(result, section), field) = @field(@field(draft, section), field);
                    }
                }
            }
        }
    }
    if (dirty.isSet(plugin_preferences_index)) result.plugin_preferences = draft.plugin_preferences;
    if (dirty.isSet(keys_index)) result.keys = draft.keys;
    if (dirty.isSet(providers_index)) {
        result.ai.provider_count = draft.ai.provider_count;
        result.ai.providers = draft.ai.providers;
    }
    return result;
}

pub fn changed(a: config.Config, b: config.Config) FieldSet {
    var result: FieldSet = .empty;
    for (0..field_count) |index| if (!fieldEqual(a, b, index)) result.set(index);
    return result;
}

test "schema merge preserves external fields and explicitly edited conflicts win" {
    const baseline: config.Config = .{};
    var latest = baseline;
    latest.ui.font_size = 20;
    latest.ssh.term = "vt100";
    var draft = baseline;
    draft.ui.font_size = 18;
    const dirty = changed(baseline, draft);
    const result = merge(latest, draft, dirty);
    try std.testing.expectEqual(@as(u8, 18), result.ui.font_size);
    try std.testing.expectEqualStrings("vt100", result.ssh.term);
    try std.testing.expectEqual(@as(usize, 1), dirty.count());
}

test "schema uses string content and actual reconnect backoff values" {
    var a: config.Config = .{};
    var b = a;
    var name = [_]u8{ 'd', 'a', 'r', 'k' };
    b.ui.theme = &name;
    try std.testing.expectEqual(@as(usize, 0), changed(a, b).count());
    a.ssh.reconnect_backoff[0] = 2;
    try std.testing.expect(changed(a, b).isSet(find("ssh", "reconnect_backoff").?));
    for (fields, 0..) |entry, index| try std.testing.expectEqual(index, find(entry.section, entry.key).?);
}
