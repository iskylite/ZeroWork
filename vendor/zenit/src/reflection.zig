//! Field descriptors used by the UI's compile-time schema transformations.
//! Zig exposes parallel field arrays; this module keeps each schema field together
//! while preserving its default value and explicit alignment.
const std = @import("std");

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,
    is_comptime: bool,
    alignment: ?usize,

    pub inline fn defaultValue(comptime field: StructField) ?field.type {
        const ptr: *const field.type = @ptrCast(@alignCast(field.default_value_ptr orelse return null));
        return ptr.*;
    }
};
pub const EnumField = struct { name: [:0]const u8, value: comptime_int };
pub const UnionField = struct { name: [:0]const u8, type: type, alignment: ?usize };

pub inline fn fields(comptime T: type) switch (@typeInfo(T)) {
    .@"struct" => []const StructField,
    .@"union" => []const UnionField,
    .@"enum" => []const EnumField,
    else => @compileError("expected a struct, union or enum"),
} {
    return comptime blk: {
        const info = @typeInfo(T);
        const tag = @tagName(info);
        const data = @field(info, tag);
        const Field = switch (info) {
            .@"struct" => StructField,
            .@"union" => UnionField,
            .@"enum" => EnumField,
            else => unreachable,
        };
        var result: [data.field_names.len]Field = undefined;
        for (data.field_names, 0..) |name, i| {
            result[i] = switch (info) {
                .@"struct" => .{ .name = name, .type = data.field_types[i], .default_value_ptr = data.field_attrs[i].default_value_ptr, .is_comptime = data.field_attrs[i].@"comptime", .alignment = data.field_attrs[i].@"align" },
                .@"union" => .{ .name = name, .type = data.field_types[i], .alignment = data.field_attrs[i].@"align" },
                .@"enum" => .{ .name = name, .value = data.field_values[i] },
                else => unreachable,
            };
        }
        const value = result;
        break :blk &value;
    };
}

pub fn Struct(comptime descriptors: []const StructField) type {
    var names: [descriptors.len][:0]const u8 = undefined;
    var types: [descriptors.len]type = undefined;
    var attrs: [descriptors.len]std.lang.Type.Struct.FieldAttributes = undefined;
    for (descriptors, 0..) |field, i| {
        names[i] = field.name;
        types[i] = field.type;
        attrs[i] = .{ .@"comptime" = field.is_comptime, .@"align" = field.alignment, .default_value_ptr = field.default_value_ptr };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn Enum(comptime Tag: type, comptime descriptors: []const EnumField) type {
    var names: [descriptors.len][:0]const u8 = undefined;
    var values: [descriptors.len]Tag = undefined;
    for (descriptors, 0..) |field, i| {
        names[i] = field.name;
        values[i] = @intCast(field.value);
    }
    return @Enum(Tag, .exhaustive, &names, &values);
}

test "schema reconstruction preserves defaults, comptime fields and alignment" {
    const Original = struct {
        value: u32 align(16) = 42,
        comptime label: []const u8 = "schema",
    };
    const Copy = Struct(fields(Original));
    const v: Copy = .{};
    try std.testing.expectEqual(@as(u32, 42), v.value);
    try std.testing.expectEqualStrings("schema", v.label);
    try std.testing.expectEqual(@alignOf(Original), @alignOf(Copy));
    try std.testing.expect(@typeInfo(Copy).@"struct".field_attrs[1].@"comptime");
}

/// Function parameter descriptors for the schema validators.
pub inline fn params(comptime Function: type) []const Param {
    return paramsInfo(@typeInfo(Function).@"fn");
}
pub const Param = struct { type: ?type };
pub inline fn paramsInfo(comptime info: std.lang.Type.Fn) []const Param {
    return comptime blk: {
        var descriptors: [info.param_types.len]Param = undefined;
        for (info.param_types, 0..) |T, i| descriptors[i] = .{ .type = T };
        const value = descriptors;
        break :blk &value;
    };
}
