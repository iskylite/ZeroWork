//! Protocol settings present real built-ins and isolated, read-only plans.
//! This model intentionally has no install, permission or reload command.
const std = @import("std");
const registry = @import("../host/plugin_registry.zig");

pub const PlannedProtocol = enum { ftp_ftps, vnc, rdp, kvm };
pub const Selection = union(enum) { builtin: []const u8, planned: PlannedProtocol };
pub const PreviewKind = enum { capabilities, permissions, validation, incompatible, wait_sessions, acquisition, loading };
pub const Planned = struct {
    protocol: PlannedProtocol,
    name: []const u8,
    version: []const u8 = "未发布",
    abi: []const u8 = "待定义",
};
pub const plans = [_]Planned{
    .{ .protocol = .ftp_ftps, .name = "FTP / FTPS" },
    .{ .protocol = .vnc, .name = "VNC" },
    .{ .protocol = .rdp, .name = "RDP" },
    .{ .protocol = .kvm, .name = "KVM" },
};

pub const State = struct {
    selection: Selection = .{ .builtin = "local" },
    builtin_registry_snapshot: []const registry.BuiltinSnapshot,
    registry_source: registry.Registry,
    preview_kind: ?PreviewKind = null,
    settings_draft_revision: u64,
    /// A planning example only; never enters Config/raw/errors or a real job.
    validation_example_input: []const u8 = "0",
    validation_example_error: []const u8 = "超时须大于0；示例输入保留",

    pub fn init(source: registry.Registry, revision: u64) State {
        return .{ .builtin_registry_snapshot = source.snapshot(), .registry_source = source, .settings_draft_revision = revision };
    }

    pub fn refreshRegistry(self: *State, source: registry.Registry, revision: u64) void {
        self.builtin_registry_snapshot = source.snapshot();
        self.registry_source = source;
        self.settings_draft_revision = revision;
    }

    pub fn select(self: *State, selection: Selection) void {
        self.selection = selection;
        self.preview_kind = if (selection == .planned) .capabilities else null;
    }

    pub fn showPreview(self: *State, kind: PreviewKind) error{ReadOnlyBuiltin}!void {
        if (self.selection != .planned) return error.ReadOnlyBuiltin;
        self.preview_kind = kind;
    }

    /// Returning to the list preserves selection and the host's scroll state.
    pub fn returnToList(self: *State) void {
        self.preview_kind = null;
    }
};

test "protocol plans stay separate from real registration and retain selection" {
    const source = registry.Registry.builtins();
    var page = State.init(source, 7);
    try std.testing.expectEqual(@as(usize, 3), page.builtin_registry_snapshot.len);
    try std.testing.expectEqual(@as(usize, 4), plans.len);
    for (page.builtin_registry_snapshot) |entry| {
        try std.testing.expectEqual(registry.Availability.adapter_not_connected, entry.availability);
        try std.testing.expectEqualStrings(registry.plugin_version, entry.descriptor.plugin_version);
    }
    try std.testing.expectError(error.ReadOnlyBuiltin, page.showPreview(.loading));
    page.select(.{ .planned = .ftp_ftps });
    for (std.enums.values(PreviewKind)) |preview| {
        try page.showPreview(preview);
        try std.testing.expectEqual(@as(u64, 7), page.settings_draft_revision);
        try std.testing.expectEqualStrings("0", page.validation_example_input);
    }
    page.returnToList();
    try std.testing.expectEqual(PlannedProtocol.ftp_ftps, page.selection.planned);
    try std.testing.expect(page.preview_kind == null);
    for (plans) |plan| {
        try std.testing.expectEqualStrings("未发布", plan.version);
        try std.testing.expectEqualStrings("待定义", plan.abi);
    }
}
