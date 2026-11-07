//! Persistent child identity/configuration. History is stored by the existing
//! conversation Record; this descriptor contains no Worker or UI references.
const std = @import("std");
const identity = @import("../host/identity.zig");
pub const ContextMode = @import("../config/config.zig").ChildContextMode;
pub const ReusePolicy = @import("../config/config.zig").ChildReusePolicy;
pub const Defaults = struct { context_mode: ContextMode = .independent, reuse_policy: ReusePolicy = .new };
pub fn resolve(defaults: Defaults, mode: ?ContextMode, reusable: ?bool) struct { context_mode: ContextMode, reusable: bool } {
    return .{ .context_mode = mode orelse defaults.context_mode, .reusable = reusable orelse (defaults.reuse_policy == .prefer_reuse) };
}
pub const Source = struct {
    conversation: identity.ConversationId,
    content_revision: u64,
    turn: u64,
    message_count: usize,
};
pub const Draft = struct {
    request_key: []const u8,
    name: []const u8,
    context_mode: ContextMode = .independent,
    reusable: bool = false,
    model: ?@import("provider_config.zig").ModelSelection = null,
    effort: ?@import("provider.zig").Effort = null,
    skill_ids: []const []const u8 = &.{},
    mcp_ids: []const []const u8 = &.{},
};
pub const Info = struct {
    agent: identity.AgentId,
    owning_parent_conversation: identity.ConversationId,
    created_by_agent: identity.AgentId,
    request_key: []const u8,
    name: []const u8,
    context_mode: ContextMode,
    reusable: bool,
    model: ?@import("provider_config.zig").ModelSelection = null,
    effort: ?@import("provider.zig").Effort = null,
    skill_ids: []const []const u8 = &.{},
    mcp_ids: []const []const u8 = &.{},
    context_source: ?Source = null,
    initial_context_hash: [32]u8 = @splat(0),

    pub fn validate(self: Info) !void {
        if (!self.agent.valid() or !self.owning_parent_conversation.valid() or !self.created_by_agent.valid()) return error.InvalidChildIdentity;
        inline for (.{ self.skill_ids, self.mcp_ids }) |ids| {
            if (ids.len > 32) return error.InvalidChildConfiguration;
            for (ids, 0..) |key, i| {
                try @import("../config/ai_extensions.zig").identifier(key);
                for (ids[0..i]) |prior| if (std.mem.eql(u8, prior, key)) return error.InvalidChildConfiguration;
            }
        }
        try validateText(self.name, 128);
        try validateText(self.request_key, 128);
        if (self.model) |model| {
            try validateText(model.provider_id, 128);
            try validateText(model.model_id, 256);
        }
        if (self.context_mode == .inherit) {
            const source = self.context_source orelse return error.MissingInheritanceSnapshot;
            if (!source.conversation.eql(self.owning_parent_conversation) or source.content_revision == 0 or source.turn == 0 or source.message_count == 0 or source.message_count > @import("wire_history.zig").History.max_messages) return error.InvalidInheritanceSnapshot;
        } else if (self.context_source != null) return error.InvalidInheritanceSnapshot;
    }
    pub fn clone(self: Info, a: std.mem.Allocator) !Info {
        var result = self;
        result.request_key = try a.dupe(u8, self.request_key);
        result.name = try a.dupe(u8, self.name);
        if (self.model) |model| result.model = .{ .provider_id = try a.dupe(u8, model.provider_id), .model_id = try a.dupe(u8, model.model_id) };
        inline for (.{ "skill_ids", "mcp_ids" }) |field| {
            const ids = @field(self, field);
            const copy = try a.alloc([]const u8, ids.len);
            for (ids, copy) |key, *item| item.* = try a.dupe(u8, key);
            @field(result, field) = copy;
        }
        return result;
    }
};
pub const Owned = struct {
    arena: std.heap.ArenaAllocator,
    info: Info,
    pub fn init(a: std.mem.Allocator, info: Info) !Owned {
        try info.validate();
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = try info.clone(arena.allocator());
        return .{ .arena = arena, .info = owned };
    }
    pub fn deinit(self: *Owned) void {
        self.arena.deinit();
    }
};
fn validateText(value: []const u8, max: usize) !void {
    if (std.mem.trim(u8, value, " \t\r\n").len == 0 or value.len > max or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidChildConfiguration;
}

/// User-editable next-task preferences. Creation provenance in Info is immutable.
pub const Settings = struct {
    name: []const u8,
    reusable: bool,
    model: ?@import("provider_config.zig").ModelSelection = null,
    effort: ?@import("provider.zig").Effort = null,
    thinking: ?bool = null,
    session_retention: ?@import("../config/config.zig").SessionRetention = null,
    permission: @import("../config/config.zig").PermissionMode = .confirm,
    execution_mode: @import("../config/config.zig").ExecutionMode = .auto,
    skill_ids: []const []const u8 = &.{},
    mcp_ids: []const []const u8 = &.{},
    targets: []const identity.SessionHandle = &.{},
    pub fn fromInfo(info: Info) Settings {
        return .{ .name = info.name, .reusable = info.reusable, .model = info.model, .effort = info.effort, .skill_ids = info.skill_ids, .mcp_ids = info.mcp_ids };
    }
    pub fn validate(self: Settings, info: Info) !void {
        var copy = info;
        copy.name = self.name;
        copy.model = self.model;
        copy.effort = self.effort;
        copy.skill_ids = self.skill_ids;
        copy.mcp_ids = self.mcp_ids;
        try copy.validate();
        inline for (.{ "skill_ids", "mcp_ids" }) |field| for (@field(self, field)) |key| {
            for (@field(info, field)) |ceiling| if (std.mem.eql(u8, key, ceiling)) break else {} else return error.ChildCapabilityExpansion;
        };
        if (self.targets.len > 32) return error.InvalidChildConfiguration;
        for (self.targets, 0..) |target, i| {
            if (@backingInt(target.session_id) == 0 or target.generation == 0) return error.InvalidChildConfiguration;
            for (self.targets[0..i]) |prior| if (prior.session_id == target.session_id) return error.InvalidChildConfiguration;
        }
    }
};
pub const SettingsOwned = struct {
    arena: std.heap.ArenaAllocator,
    value: Settings,
    pub fn init(a: std.mem.Allocator, value: Settings, info: Info) !SettingsOwned {
        try value.validate(info);
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        var copy = value;
        copy.name = try alloc.dupe(u8, value.name);
        if (value.model) |model| copy.model = .{ .provider_id = try alloc.dupe(u8, model.provider_id), .model_id = try alloc.dupe(u8, model.model_id) };
        inline for (.{ "skill_ids", "mcp_ids" }) |field| {
            const ids = @field(value, field);
            const keys = try alloc.alloc([]const u8, ids.len);
            for (ids, keys) |key, *slot| slot.* = try alloc.dupe(u8, key);
            @field(copy, field) = keys;
        }
        copy.targets = try alloc.dupe(identity.SessionHandle, value.targets);
        return .{ .arena = arena, .value = copy };
    }
    pub fn deinit(self: *SettingsOwned) void {
        self.arena.deinit();
    }
};
