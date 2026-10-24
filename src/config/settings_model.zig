const std = @import("std");
const config = @import("config.zig");
const pages = @import("settings_pages.zig");
const values = @import("settings_values.zig");
const schema = @import("settings_schema.zig");

pub const Model = struct {
    value: config.Config = .{},
    original: config.Config = .{},
    page_index: usize = 0,
    key_index: usize = 0,
    dirty: bool = false,
    locked: bool = false,

    pub fn page(self: Model) pages.Page {
        return pages.pages[self.page_index];
    }

    pub fn selectPage(self: *Model, index: usize) void {
        if (self.locked) return;
        self.page_index = @min(index, pages.pages.len - 1);
        self.key_index = 0;
    }

    pub fn selectNextPage(self: *Model) void {
        self.selectPage((self.page_index + 1) % pages.pages.len);
    }
    pub fn selectPreviousPage(self: *Model) void {
        self.selectPage(if (self.page_index == 0) pages.pages.len - 1 else self.page_index - 1);
    }

    pub fn pageKeys(self: Model, buffer: []pages.ConfigKey) []pages.ConfigKey {
        var count: usize = 0;
        for (pages.keys) |entry| {
            if (std.mem.eql(u8, entry.page, self.page().name)) {
                if (count == buffer.len) break;
                buffer[count] = entry;
                count += 1;
            }
        }
        return buffer[0..count];
    }

    pub fn selectKey(self: *Model, index: usize) void {
        if (self.locked) return;
        var count: usize = 0;
        for (pages.keys) |entry| {
            if (std.mem.eql(u8, entry.page, self.page().name)) count += 1;
        }
        self.key_index = if (count == 0) 0 else @min(index, count - 1);
    }

    pub fn selectedKey(self: Model) ?pages.ConfigKey {
        var index: usize = 0;
        for (pages.keys) |entry| {
            if (!std.mem.eql(u8, entry.page, self.page().name)) continue;
            if (index == self.key_index) return entry;
            index += 1;
        }
        return null;
    }

    pub fn selectedValue(self: Model) ?values.Value {
        const key = self.selectedKey() orelse return null;
        return values.read(self.value, key.section, key.key);
    }

    pub fn editSelected(self: *Model, next: values.Value) values.WriteError!void {
        if (self.locked) return error.SettingsBusy;
        const key = self.selectedKey() orelse return error.UnknownKey;
        try values.writeConfig(&self.value, key.section, key.key, next);
        self.dirty = schema.changed(self.original, self.value).count() != 0;
    }

    /// Restore the product defaults as a draft; the saved baseline stays intact
    /// until Save succeeds, so Discard can undo a defaults reset.
    pub fn resetDefaults(self: *Model) void {
        if (self.locked) return;
        self.value = config.resetDefaults();
        self.dirty = schema.changed(self.original, self.value).count() != 0;
    }

    pub fn discard(self: *Model) void {
        if (self.locked) return;
        self.value = self.original;
        self.dirty = false;
    }

    pub fn setOriginal(self: *Model, value: config.Config) void {
        self.value = value;
        self.original = value;
        self.dirty = false;
    }
};

test "settings model navigates pages and edits selected value" {
    var model: Model = .{};
    try std.testing.expectEqualStrings("外观与主题", model.page().name);
    try std.testing.expectEqualStrings("dark", model.selectedValue().?.text);
    model.selectNextPage();
    try std.testing.expectEqualStrings("快捷键", model.page().name);
    model.value.ui.font_size = 22;
    model.original.ui.font_size = 14;
    model.selectPage(4);
    try std.testing.expectEqualStrings("AI 辅助", model.page().name);
    model.selectKey(1); // permission_mode, rather than the default_provider row
    try model.editSelected(.{ .text = "auto" });
    try std.testing.expectEqual(config.PermissionMode.auto, model.value.ai.permission_mode);
    try std.testing.expect(model.dirty);
    model.discard();
    try std.testing.expect(!model.dirty);
}

test "default reset is a draft change and discard restores the saved baseline" {
    var model: Model = .{};
    model.value.ui.font_size = 22;
    model.original = model.value;
    model.resetDefaults();
    try std.testing.expectEqual(@as(u8, 14), model.value.ui.font_size);
    try std.testing.expectEqual(@as(u8, 22), model.original.ui.font_size);
    try std.testing.expect(model.dirty);
    model.discard();
    try std.testing.expectEqual(@as(u8, 22), model.value.ui.font_size);
    try std.testing.expect(!model.dirty);
}
