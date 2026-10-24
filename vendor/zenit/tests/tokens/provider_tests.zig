const std = @import("std");
const theme = @import("example");
const edge = @import("edge");
const empty = @import("empty");
const sv = @import("zenit_style_values");
const preset = @import("preset_fixture");
const TOKENS = theme.refs;

test "real generated provider has unified typed refs and canonical renderer values" {
    try std.testing.expectEqual(theme.Token(.color), @TypeOf(TOKENS.color.surface));
    try std.testing.expectEqual(theme.Token(.color), @TypeOf(TOKENS.color.blue.@"500"));
    try std.testing.expect(theme.Token(.color) != theme.Token(.font_size));
    try std.testing.expectEqual(sv.Color, @TypeOf(theme.modes.dark.tokens.color.surface));
    try std.testing.expectEqual(@as(f32, 32), theme.resolve(.font_size, TOKENS.font_size.xxxl, &theme.modes.dark));
    try std.testing.expectEqual(@as(f32, 32), theme.resolve(.font_size, TOKENS.font_size.title, &theme.modes.dark));
    try std.testing.expectEqual(@as(u8, 0x93), theme.resolve(.color, TOKENS.color.action, &theme.modes.dark).r);
    try std.testing.expectEqual(@as(u8, 255), theme.resolve(.color, TOKENS.color.action, &theme.modes.high_contrast).r);
    try std.testing.expectEqual(@as(u8, 0), theme.resolve(.color, TOKENS.color.action, &theme.modes.high_contrast).b);
}
test "escaped names and empty categories compile as actual Zig" {
    try std.testing.expectEqual(@as(f32, 32), edge.resolve(.font_size, edge.refs.font_size.xLargeBlaBla, &edge.modes.light));
    try std.testing.expectEqual(@as(f32, 1), edge.resolve(.space, edge.refs.space.group.@"500", &edge.modes.light));
    try std.testing.expectEqual(@as(f32, 2), edge.resolve(.space, edge.refs.space.group.@"error", &edge.modes.light));
    try std.testing.expectEqual(@as(f32, 3), edge.resolve(.space, edge.refs.space.group.@"text-hairline", &edge.modes.light));
    try std.testing.expectEqual(@as(f32, 4), edge.resolve(.space, edge.refs.space.group._, &edge.modes.light));
    try std.testing.expectEqual(@as(f32, 5), edge.resolve(.space, edge.refs.space.group.semantic, &edge.modes.light));
    try std.testing.expectEqual(@as(f32, 24), edge.resolve(.size, edge.refs.size.fill, &edge.modes.light));
    try std.testing.expectEqual(@as(usize, 0), @import("zenit_reflection").fields(empty.Token(.color)).len);
    try std.testing.expectEqual(@as(usize, 0), @import("zenit_reflection").fields(@TypeOf(empty.modes.light.tokens.color)).len);
    try std.testing.expect(!@hasField(empty.Values, "system"));
    try std.testing.expect(!@hasField(@TypeOf(empty.modes.dark.tokens.color), "accent"));
}

test "default JSON preserves material values in all three modes after classification and naming cleanup" {
    @setEvalBranchQuota(10000);
    const generated = @import("default");
    inline for (.{ "light", "dark", "high_contrast" }) |mode| {
        const old = @field(preset, mode);
        const new = @field(generated.modes, mode);
        inline for (@import("zenit_reflection").fields(preset.ThemeTokens)) |category| {
            if (comptime std.mem.eql(u8, category.name, "name") or std.mem.eql(u8, category.name, "scheme") or std.mem.eql(u8, category.name, "control")) continue;
            inline for (@import("zenit_reflection").fields(category.type)) |field| {
                // Component size variants moved to recipes; their geometry is tested with the components.
                if (comptime std.mem.eql(u8, category.name, "size") and (std.mem.eql(u8, field.name, "badge_sm") or std.mem.eql(u8, field.name, "badge_md"))) continue;
                const key = comptime if (std.mem.eql(u8, category.name, "space")) renamedSpace(field.name) else field.name;
                try std.testing.expectEqualDeep(@field(@field(old, category.name), field.name), @field(@field(new.tokens, category.name), key));
            }
        }
    }
}

fn renamedSpace(comptime old: []const u8) []const u8 {
    const names = .{ ._0 = "space0", ._0_5 = "space50", ._1 = "space100", ._1_5 = "space150", ._2 = "space200", ._3 = "space300", ._4 = "space400", ._6 = "space600", ._8 = "space800", ._10 = "space1000", ._12 = "space1200" };
    return @field(names, old);
}
