//! V0.7 §3.7 child role templates: named role→slot maps with the four-layer
//! fallback chain. Stage 1–2 ships storage + fallback resolution; stage 3
//! enables the slots for swarm/boost parameter packs.
//! Masks are allow-lists that only NARROW capability (never expand): the
//! effective grant stays 父授权投影 ∩ create 参数 ∩ 模板槽掩码.
const std = @import("std");

/// Template slot roles (value domain fixed in this version). The verifier slot
/// is hit by purpose=verify/challenge, not by the role enum.
pub const Role = enum { parent, planner, verifier, worker, batch };

/// Per-slot configuration: model+effort, optional narrowing masks.
/// Null mask field means "everything" (template carries model meaning only).
pub const Slot = struct {
    model: ?@import("../ai/provider_config.zig").ModelSelection = null,
    effort: ?@import("../ai/provider.zig").Effort = null,
    /// Allowed skill ids; empty means the parent's projection unchanged.
    skill_ids: ?[]const []const u8 = null,
    /// Allowed tool ids; empty means the parent's projection unchanged.
    tool_ids: ?[]const []const u8 = null,
};

/// Named template. The built-in "均衡" template (all slots inherit, no
/// masks) is the default for new conversations, matching V0.4 behavior.
pub const Template = struct {
    name: []const u8,
    slots: [5]Slot = @splat(.{}),
    pub fn validate(self: Template) !void {
        if (std.mem.trim(u8, self.name, " \t\r\n").len == 0 or self.name.len > 64 or !std.unicode.utf8ValidateSlice(self.name)) return error.InvalidRoleTemplate;
        for (self.slots) |slot| {
            if (slot.skill_ids) |ids| for (ids) |id| {
                if (id.len == 0 or id.len > 128 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidRoleTemplate;
            };
            if (slot.tool_ids) |ids| for (ids) |id| {
                if (id.len == 0 or id.len > 128 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidRoleTemplate;
            };
        }
    }
};

pub const builtin = Template{ .name = "均衡" };

/// V0.7 §3.7 effort adaptation used when a configured slot has no model/effort:
/// batch=low, worker=medium, planner/verifier=high before inheriting.
pub fn adaptedEffort(role: Role) ?@import("../ai/provider.zig").Effort {
    return switch (role) {
        .parent, .worker => .medium,
        .planner, .verifier => .high,
        .batch => .low,
    };
}

/// Resolve the effective slot for a create through the four-layer chain:
///   ① create 显式 model+effort（最高）
///   ② 活动模板的对应角色槽
///   ③ 同模型 effort 适配（batch=low、worker=medium、planner/verifier=high）
///   ④ inherit（父会话模型 + 会话 effort）
/// Returns the layer that produced each part so callers can disclose it.
pub const Resolution = struct {
    model: ?@import("../ai/provider_config.zig").ModelSelection = null,
    effort: ?@import("../ai/provider.zig").Effort = null,
    model_layer: Layer = .inherit,
    effort_layer: Layer = .inherit,
    slot: Slot = .{},
};
pub const Layer = enum { explicit, template, adapted, inherit };

pub fn resolve(
    comptime role: Role,
    explicit_model: ?@import("../ai/provider_config.zig").ModelSelection,
    explicit_effort: ?@import("../ai/provider.zig").Effort,
    template: Template,
    parent_model: ?@import("../ai/provider_config.zig").ModelSelection,
    parent_effort: ?@import("../ai/provider.zig").Effort,
) Resolution {
    var result: Resolution = .{};
    const slot = template.slots[@intFromEnum(role)];
    result.slot = slot;
    // ① explicit wins for whatever it provides.
    if (explicit_model) |model| {
        result.model = model;
        result.model_layer = .explicit;
    }
    if (explicit_effort) |effort| {
        result.effort = effort;
        result.effort_layer = .explicit;
    }
    // ② the active template's slot fills the remainder.
    if (result.model == null and slot.model != null) {
        result.model = slot.model;
        result.model_layer = .template;
    }
    if (result.effort == null and slot.effort != null) {
        result.effort = slot.effort;
        result.effort_layer = .template;
    }
    // ④ inherit the parent conversation model when still unset.
    if (result.model == null) {
        result.model = parent_model;
        result.model_layer = .inherit;
    }
    // ③ same-model effort adaptation once the effective model is known
    // (slot, explicit or inherited): batch=low, worker=medium,
    // planner/verifier=high.
    if (result.effort == null and result.model != null) {
        result.effort = adaptedEffort(role);
        result.effort_layer = .adapted;
    }
    // ④ inherit the parent conversation effort last (a session-level effort
    // pins the floor; without one the adaptation applies).
    if (result.effort == null) {
        result.effort = parent_effort;
        result.effort_layer = .inherit;
    }
    return result;
}

/// Masks only narrow: intersection with the parent's granted projection is
/// applied by the caller (plugin_tools catalog pruning, same path as
/// purpose=verify). This helper intersects two id lists.
pub fn intersectIds(a: std.mem.Allocator, granted: []const []const u8, mask: ?[]const []const u8) ![]const []const u8 {
    const allowed = mask orelse return granted;
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for (granted) |id| {
        for (allowed) |candidate| if (std.mem.eql(u8, id, candidate)) {
            try out.append(a, id);
            break;
        };
    }
    return out.toOwnedSlice(a);
}

/// V0.7 §3.7/§5: the persisted template list on [ai] child_role_templates.
/// JSON-encoded like extensions; the built-in 均衡 template is implicit.
pub const Stored = struct {
    name: []const u8,
    /// Per-slot model ids (empty = inherit), indexed by Role.
    models: [5]?[]const u8 = @splat(null),
    /// Per-slot efforts (null = adapted/inherit).
    efforts: [5]?@import("../ai/provider.zig").Effort = @splat(null),
    /// Older configurations store only a model ID. Resolve it only when unique.
    providers: [5]?[]const u8 = @splat(null),
    is_default: bool = false,

    pub fn active(templates: []const Stored) ?Stored {
        for (templates) |item| if (item.is_default) return item;
        return null;
    }

    pub fn selection(self: Stored, ai: @import("config.zig").Ai, role: Role) ?@import("../ai/provider_config.zig").ModelSelection {
        const index = @intFromEnum(role);
        const model_id = self.models[index] orelse return null;
        const provider_config = @import("../ai/provider_config.zig");
        if (self.providers[index]) |provider_id| {
            const key: provider_config.ModelSelection = .{ .provider_id = provider_id, .model_id = model_id };
            _ = provider_config.fromSettingsSelection(ai, key) catch return null;
            return key;
        }
        var resolved: ?provider_config.ModelSelection = null;
        for (ai.providers[0..@min(ai.provider_count, ai.providers.len)]) |provider| {
            if (!provider.enabled) continue;
            const key: provider_config.ModelSelection = .{ .provider_id = provider_config.providerId(provider), .model_id = model_id };
            if (!provider_config.hasConfiguredModel(ai, key)) continue;
            if (resolved != null) return null;
            resolved = key;
        }
        return resolved;
    }
    /// Slot index by role order parent=0,planner=1,verifier=2,worker=3,batch=4.
    pub fn encode(a: std.mem.Allocator, list: []const Stored) ![]const u8 {
        return std.json.Stringify.valueAlloc(a, list, .{});
    }
    pub fn decode(a: std.mem.Allocator, text: []const u8) ![]Stored {
        return std.json.parseFromSliceLeaky([]Stored, a, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidRoleTemplate,
        };
    }
    pub fn validate(self: Stored) !void {
        if (std.mem.trim(u8, self.name, " \t\r\n").len == 0 or self.name.len > 64 or !std.unicode.utf8ValidateSlice(self.name) or std.mem.eql(u8, self.name, builtin.name)) return error.InvalidRoleTemplate;
        for (self.models, self.providers) |model, provider| {
            if (model) |value| if (value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidRoleTemplate;
            if (provider) |value| if (model == null or value.len == 0 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidRoleTemplate;
        }
    }
};

test "v0.7 stored templates round trip json" {
    const a = std.testing.allocator;
    const list = [_]Stored{.{ .name = "攻坚", .models = @splat(null), .efforts = .{ null, .high, null, .medium, null } }};
    const encoded = try Stored.encode(a, &list);
    defer a.free(encoded);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const decoded = try Stored.decode(arena.allocator(), encoded);
    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualStrings("攻坚", decoded[0].name);
    try std.testing.expectEqual(@import("../ai/provider.zig").Effort.high, decoded[0].efforts[1].?);
    try std.testing.expectError(error.InvalidRoleTemplate, Stored.decode(arena.allocator(), "not json"));
}

test "v0.7 role templates four-layer fallback chain resolves per layer" {
    const P = @import("../ai/provider_config.zig");
    const E = @import("../ai/provider.zig").Effort;
    const parent_model: P.ModelSelection = .{ .provider_id = "magpie", .model_id = "parent-model" };
    // ① explicit wins.
    var template = builtin;
    template.slots[@intFromEnum(Role.worker)] = .{ .model = .{ .provider_id = "slot", .model_id = "slot-model" }, .effort = .high };
    const explicit = resolve(.worker, .{ .provider_id = "explicit", .model_id = "explicit-model" }, .low, template, parent_model, .max);
    try std.testing.expectEqualStrings("explicit-model", explicit.model.?.model_id);
    try std.testing.expectEqual(Layer.explicit, explicit.model_layer);
    try std.testing.expectEqual(E.low, explicit.effort);
    // ② template slot fills an omitted model.
    const from_slot = resolve(.worker, null, null, template, parent_model, .max);
    try std.testing.expectEqualStrings("slot-model", from_slot.model.?.model_id);
    try std.testing.expectEqual(Layer.template, from_slot.model_layer);
    try std.testing.expectEqual(E.high, from_slot.effort);
    // ③ effort adaptation when the model is inherited: worker=medium.
    const adapted = resolve(.worker, null, null, builtin, parent_model, null);
    try std.testing.expectEqualStrings("parent-model", adapted.model.?.model_id);
    try std.testing.expectEqual(Layer.inherit, adapted.model_layer);
    try std.testing.expectEqual(E.medium, adapted.effort);
    try std.testing.expectEqual(Layer.adapted, adapted.effort_layer);
    // ④ full inherit: batch adapts low when explicit model given.
    const batched = resolve(.batch, .{ .provider_id = "p", .model_id = "m" }, null, builtin, parent_model, null);
    try std.testing.expectEqual(E.low, batched.effort);
    // planner/verifier adapt high.
    const planned = resolve(.planner, .{ .provider_id = "p", .model_id = "m" }, null, builtin, parent_model, null);
    try std.testing.expectEqual(E.high, planned.effort);
}

test "v0.7 mask intersection only narrows" {
    const a = std.testing.allocator;
    const granted = [_][]const u8{ "skill-a", "skill-b", "skill-c" };
    // null mask keeps the grant unchanged.
    const unchanged = try intersectIds(a, &granted, null);
    try std.testing.expectEqual(@as(usize, 3), unchanged.len);
    // A mask narrows to the intersection.
    const mask = [_][]const u8{ "skill-b", "skill-d" };
    const narrowed = try intersectIds(a, &granted, &mask);
    defer a.free(narrowed);
    try std.testing.expectEqual(@as(usize, 1), narrowed.len);
    try std.testing.expectEqualStrings("skill-b", narrowed[0]);
}

test "v0.7 builtin template validates and defaults to inherit" {
    try builtin.validate();
    try std.testing.expectError(error.InvalidRoleTemplate, (Template{ .name = " " }).validate());
}
