//! Prepared appearance resources accompany the existing Config transaction.
//! Workers own IO/decoding; commit only validates receipts and publishes once.
const std = @import("std");
const runtime = @import("runtime_config.zig");
const controller = @import("settings_controller.zig");
const themes = @import("theme_registry.zig");
const material = @import("background_asset.zig");
const schema = runtime.schema;

/// Metrics come from appearance_font.resolve using the application's existing
/// FontRegistry. This module never creates another font system or estimates M.
pub const Typography = struct {
    requested_family: []const u8,
    actual_family: []const u8,
    size: f32,
    weight: u16,
    family_id: u16,
    cell_width: f32,
    ascent: f32,
    descent: f32,
    fallback: bool = false,

    pub fn fromResolved(resolved: anytype) Typography {
        return .{ .requested_family = resolved.requested_family, .actual_family = resolved.actual_family, .size = resolved.requested_size, .weight = @backingInt(resolved.actual_weight), .family_id = resolved.family_id, .cell_width = resolved.cell_width, .ascent = resolved.ascent, .descent = resolved.descent, .fallback = resolved.fallback_reason != null };
    }
};
pub const Layout = struct {
    font: Typography,
    line_pixels: f32,
    cursor: enum { block, bar, underline },
    timestamp_gutter: bool,
    input_line_highlight: bool,
    sidebar_collapsed: bool,
};
pub const Theme = struct {
    id: []const u8,
    display_name: []const u8,
    bg: u32,
    fg: u32,
    cursor: u32,
    selection: ?u32,
    ansi: [16]u32,
    ui_tokens: themes.UiTokens,
};
/// Optional renderer preflight. It must finish texture allocation before the
/// Config commit; its own receipt remains caller-owned until publish/abort.
pub const MaterialPreflight = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque, *const material.Prepared) anyerror!void,
};
pub const Preparation = struct {
    snapshot: ?runtime.Snapshot,
    expected_revision: u64,
    fields: schema.FieldSet,
    theme: Theme,
    layout: Layout,
    asset: ?material.Prepared = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Preparation) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        if (self.asset) |*asset| asset.deinit(self.allocator);
        self.* = undefined;
    }
};

/// A committed projection owns its strings and CPU image until the next publish.
/// Asynchronous readers copy the values/resources they need; Config consumers
/// use Snapshot.init for their own copy. No UI node is held here.
pub const State = struct {
    allocator: std.mem.Allocator,
    snapshot: ?runtime.Snapshot = null,
    theme: ?Theme = null,
    layout: ?Layout = null,
    asset: ?material.Prepared = null,
    theme_revision: u64 = 0,
    layout_revision: u64 = 0,
    material_revision: u64 = 0,

    pub fn deinit(self: *State) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        if (self.asset) |*asset| asset.deinit(self.allocator);
        self.* = undefined;
    }
    /// A direct/immediate global update uses the very same RuntimeConfig
    /// replacement as settings Save. Failure leaves all projections unchanged.
    pub fn commit(self: *State, io: std.Io, dir: std.Io.Dir, registry: *themes.Registry, target: *runtime.RuntimeConfig, config_prepared: *runtime.Prepared, appearance: *Preparation, installation: ?*themes.Installation) !void {
        try validateCommit(target, config_prepared, appearance, registry, installation);
        try target.commitPrepared(io, dir, config_prepared);
        if (installation) |receipt| receipt.commit(registry);
        self.publish(appearance);
    }
    pub fn completeSettings(self: *State, io: std.Io, dir: std.Io.Dir, registry: *themes.Registry, settings: *controller.Controller, target: *runtime.RuntimeConfig, request: *controller.SaveRequest, appearance: *Preparation, installation: ?*themes.Installation) !bool {
        if (request.draft_id != settings.draft_id or settings.save_operation != request.operation_id) return false;
        validateCommit(target, &request.prepared, appearance, registry, installation) catch |err| {
            _ = settings.failSave(request, err);
            return err;
        };
        if (!try settings.completeSave(io, dir, target, request)) return false;
        if (installation) |receipt| receipt.commit(registry);
        self.publish(appearance);
        return true;
    }
    fn publish(self: *State, prepared: *Preparation) void {
        const next = prepared.snapshot.?;
        const revision = next.value.config_revision;
        if (self.snapshot == null or changed(prepared.fields, .theme)) self.theme_revision = revision;
        if (self.snapshot == null or changed(prepared.fields, .layout)) self.layout_revision = revision;
        if (self.snapshot == null or changed(prepared.fields, .material)) self.material_revision = revision;
        if (self.snapshot) |*old| old.deinit();
        self.snapshot = next;
        prepared.snapshot = null;
        self.theme = prepared.theme;
        self.layout = prepared.layout;
        if (prepared.asset) |asset| {
            if (self.asset) |*old| old.deinit(self.allocator);
            self.asset = asset;
            prepared.asset = null;
        }
    }
};

/// Consumes asset only on success; on failure its caller still owns it.
/// An unchanged font/image can reuse the committed State. New images have
/// already been read/decoded by BackgroundLoad on a bounded worker.
pub fn prepare(allocator: std.mem.Allocator, registry: *const themes.Registry, config_prepared: *runtime.Prepared, current: ?*const State, font: ?Typography, asset: ?*material.Prepared, preflight: ?MaterialPreflight) !Preparation {
    const candidate = config_prepared.owned orelse return error.AlreadyCommitted;
    const value = candidate.value;
    const record = registry.get(value.ui.theme) orelse return error.UnknownTheme;
    var typography = font orelse if (current) |state| if (state.layout) |layout| layout.font else return error.FontNotPrepared else return error.FontNotPrepared;
    const expected_weight: u16 = if (std.mem.eql(u8, value.ui.font_weight, "light")) 300 else if (std.mem.eql(u8, value.ui.font_weight, "regular")) 400 else if (std.mem.eql(u8, value.ui.font_weight, "medium")) 500 else if (std.mem.eql(u8, value.ui.font_weight, "bold")) 700 else return error.InvalidWeight;
    if (!std.mem.eql(u8, typography.requested_family, value.ui.font_family) or typography.size != @as(f32, @floatFromInt(value.ui.font_size)) or typography.weight != expected_weight or typography.actual_family.len == 0 or !std.math.isFinite(typography.cell_width) or typography.cell_width <= 0 or !std.math.isFinite(typography.ascent) or typography.ascent <= 0 or !std.math.isFinite(typography.descent) or typography.descent < 0) return error.FontNotPrepared;
    var selected_asset: ?*const material.Prepared = if (asset) |selected| selected else null;
    if (selected_asset == null) if (current) |state| {
        if (state.asset) |*existing| selected_asset = existing;
    };
    if (value.ui.materials.background.enabled) {
        const selected = selected_asset orelse return error.BackgroundNotPrepared;
        if (!std.mem.eql(u8, selected.path, value.ui.materials.background.path)) return error.BackgroundNotPrepared;
        if (preflight) |check| try check.check(check.context, selected);
    }
    var owned = try runtime.Snapshot.init(allocator, value);
    errdefer owned.deinit();
    typography.requested_family = owned.value.ui.font_family;
    typography.actual_family = try owned.arena.allocator().dupe(u8, typography.actual_family);
    const theme: Theme = .{ .id = try owned.arena.allocator().dupe(u8, record.id), .display_name = try owned.arena.allocator().dupe(u8, record.theme.name), .bg = record.theme.bg, .fg = record.theme.fg, .cursor = record.theme.cursor, .selection = record.theme.selection, .ansi = record.theme.ansi, .ui_tokens = record.ui_tokens };
    if (value.ui.materials.background.enabled) try config_prepared.confirmBackground(selected_asset.?);
    const result: Preparation = .{ .allocator = allocator, .snapshot = owned, .expected_revision = config_prepared.expected_revision, .fields = config_prepared.changed_fields, .theme = theme, .layout = .{ .font = typography, .line_pixels = @as(f32, @floatFromInt(value.ui.font_size)) * value.ui.line_height, .cursor = std.meta.stringToEnum(@FieldType(Layout, "cursor"), value.ui.cursor_style) orelse return error.InvalidCursor, .timestamp_gutter = value.ui.timestamp_gutter, .input_line_highlight = value.ui.input_line_highlight, .sidebar_collapsed = value.ui.sidebar_collapsed }, .asset = if (asset) |selected| selected.* else null };
    if (asset) |selected| selected.* = undefined;
    return result;
}

fn validateCommit(target: *const runtime.RuntimeConfig, prepared: *runtime.Prepared, appearance: *const Preparation, registry: *const themes.Registry, installation: ?*themes.Installation) !void {
    const candidate = prepared.owned orelse return error.AlreadyCommitted;
    const snapshot = appearance.snapshot orelse return error.AlreadyPublished;
    if (appearance.expected_revision != target.value.config_revision or prepared.expected_revision != appearance.expected_revision) return error.StaleConfigRevision;
    if (!std.meta.eql(appearance.fields, prepared.changed_fields) or snapshot.value.config_revision != candidate.value.config_revision or schema.changed(snapshot.value, candidate.value).count() != 0) return error.MismatchedAppearance;
    if (installation) |receipt| {
        if (!receipt.ready) return error.ThemeNotPrepared;
        try receipt.validate(registry);
    }
    const record = registry.get(candidate.value.ui.theme) orelse return error.UnknownTheme;
    if (record.staged_for) |draft_id| {
        const receipt = installation orelse return error.ThemeNotPrepared;
        if (receipt.draft_id != draft_id) return error.ThemeNotPrepared;
        var contains = false;
        for (receipt.entries) |entry| if (std.mem.eql(u8, entry.id, record.id)) {
            contains = true;
            break;
        };
        if (!contains) return error.ThemeNotPrepared;
    }
    try prepared.confirmTheme(candidate.value.ui.theme);
}

const Group = enum { theme, layout, material };
fn changed(fields: schema.FieldSet, group: Group) bool {
    for (schema.fields, 0..) |field, i| {
        if (!fields.isSet(i)) continue;
        switch (group) {
            .theme => if (std.mem.eql(u8, field.section, "ui") and std.mem.eql(u8, field.key, "theme")) return true,
            .material => if (std.mem.startsWith(u8, field.section, "ui.materials")) return true,
            .layout => if (std.mem.eql(u8, field.section, "ui") and !std.mem.eql(u8, field.key, "theme")) return true,
        }
    }
    return false;
}
