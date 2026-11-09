//! Owned by the existing configuration transaction; no network/process work.
const std = @import("std");
pub const Skill = struct { id: []const u8, revision: []const u8, name: []const u8, description: []const u8, enabled: bool = true };
pub const Value = struct { name: []const u8, value: []const u8 = "", secret: bool = false, secret_ref: ?[]const u8 = null };
pub const Binding = struct {
    name: []const u8,
    // Retain the legacy tag when reading existing saved configurations.
    adapter: enum { material_text, tool } = .tool,
};
pub const Server = struct {
    id: []const u8,
    name: []const u8,
    revision: u64 = 1,
    enabled: bool = false,
    transport: enum { stdio, http } = .stdio,
    program: []const u8 = "",
    args: []const []const u8 = &.{},
    cwd: []const u8 = "",
    environment: []Value = &.{},
    endpoint: []const u8 = "",
    headers: []Value = &.{},
    timeout_ms: u32 = 30000,
    bindings: []const Binding = &.{},
    roots: []const []const u8 = &.{},
    oauth_client_id: []const u8 = "",
    oauth_scope: []const u8 = "",
};
pub const Extensions = struct {
    skills: []const Skill = &.{},
    servers: []Server = &.{},
    pub fn validate(self: Extensions) !void {
        if (self.servers.len > 16) return error.ExtensionLimit;
        for (self.skills, 0..) |skill, i| {
            if (!hex(skill.id, 32) or !hex(skill.revision, 64)) return error.InvalidSkillReference;
            try text(skill.name, 128, false);
            try text(skill.description, 1024, false);
            for (self.skills[0..i]) |prior| if (std.mem.eql(u8, prior.id, skill.id) or std.mem.eql(u8, prior.name, skill.name)) return error.DuplicateSkill;
        }
        for (self.servers, 0..) |server, i| {
            try identifier(server.id);
            try text(server.name, 128, false);
            if (server.revision == 0 or server.timeout_ms < 100 or server.timeout_ms > 120000 or server.args.len > 32 or server.environment.len > 16 or server.headers.len > 16 or server.bindings.len > 16) return error.InvalidMcpConfig;
            for (self.servers[0..i]) |prior| if (std.mem.eql(u8, prior.id, server.id)) return error.DuplicateMcpServer;
            if (server.transport == .stdio) {
                if (!std.fs.path.isAbsolute(server.program) or (server.cwd.len != 0 and !std.fs.path.isAbsolute(server.cwd))) return error.InvalidMcpProgram;
                try text(server.program, 4096, false);
                try text(server.cwd, 4096, true);
                if (server.endpoint.len != 0 or server.headers.len != 0) return error.InvalidMcpConfig;
            } else {
                try text(server.endpoint, 4096, false);
                const uri = std.Uri.parse(server.endpoint) catch return error.InvalidMcpEndpoint;
                if (uri.user != null or uri.password != null or uri.fragment != null or uri.host == null) return error.InvalidMcpEndpoint;
                const hostname = uri.host.?.percent_encoded;
                if (!std.mem.eql(u8, uri.scheme, "https") and !(std.mem.eql(u8, uri.scheme, "http") and (std.mem.eql(u8, hostname, "127.0.0.1") or std.mem.eql(u8, hostname, "localhost") or std.mem.eql(u8, hostname, "[::1]")))) return error.InvalidMcpEndpoint;
                if (server.program.len != 0 or server.args.len != 0 or server.environment.len != 0) return error.InvalidMcpConfig;
            }
            try text(server.oauth_client_id, 4096, true);
            try text(server.oauth_scope, 4096, true);
            for (server.roots) |root| {
                try text(root, 4096, false);
                const uri = std.Uri.parse(root) catch return error.InvalidMcpRoot;
                if (!std.mem.eql(u8, uri.scheme, "file") or uri.query != null or uri.fragment != null or !std.mem.startsWith(u8, root, "file:///")) return error.InvalidMcpRoot;
            }
            for (server.args) |arg| try text(arg, 4096, true);
            for ([_][]Value{ server.environment, server.headers }, 0..) |values, kind| for (values, 0..) |value, n| {
                try identifier(value.name);
                try text(value.value, 8192, true);
                if (std.mem.indexOfAny(u8, value.value, "\r\n") != null) return error.InvalidMcpValue;
                if (value.secret_ref != null and !value.secret) return error.InvalidMcpSecret;
                if (value.secret_ref) |reference| if (reference.len != 68 or !std.mem.startsWith(u8, reference, "zw1_") or !hex(reference[4..], 64)) return error.InvalidMcpSecret;
                if (kind == 1 and value.name.len >= 10 and std.ascii.eqlIgnoreCase(value.name[0..10], "mcp-param-")) return error.ReservedMcpHeader;
                if (kind == 1) for ([_][]const u8{ "mcp-method", "mcp-name", "host", "content-length", "accept", "content-type", "mcp-session-id", "mcp-protocol-version" }) |reserved| {
                    if (std.ascii.eqlIgnoreCase(value.name, reserved)) return error.ReservedMcpHeader;
                };
                for (values[0..n]) |prior| if (std.ascii.eqlIgnoreCase(prior.name, value.name)) return error.DuplicateMcpValue;
            };
            for (server.bindings, 0..) |binding, n| {
                try text(binding.name, 256, false);
                for (server.bindings[0..n]) |prior| if (std.mem.eql(u8, prior.name, binding.name)) return error.DuplicateMcpBinding;
            }
        }
    }
    pub fn clone(self: Extensions, a: std.mem.Allocator) !Extensions {
        const skills = try a.dupe(Skill, self.skills);
        for (skills) |*skill| {
            inline for (.{ "id", "revision", "name", "description" }) |key| @field(skill, key) = try a.dupe(u8, @field(skill, key));
        }
        const servers = try a.dupe(Server, self.servers);
        for (servers) |*server| {
            inline for (.{ "id", "name", "program", "cwd", "endpoint", "oauth_client_id", "oauth_scope" }) |key| @field(server, key) = try a.dupe(u8, @field(server, key));
            const args = try a.alloc([]const u8, server.args.len);
            for (args, server.args) |*dst, arg| dst.* = try a.dupe(u8, arg);
            server.args = args;
            const roots = try a.alloc([]const u8, server.roots.len);
            for (roots, server.roots) |*dst, root| dst.* = try a.dupe(u8, root);
            server.roots = roots;
            inline for (.{ "environment", "headers" }) |key| {
                @field(server, key) = try a.dupe(Value, @field(server, key));
                for (@field(server, key)) |*v| {
                    v.name = try a.dupe(u8, v.name);
                    v.value = try a.dupe(u8, v.value);
                    if (v.secret_ref) |r| v.secret_ref = try a.dupe(u8, r);
                }
            }
            const bindings = try a.dupe(Binding, server.bindings);
            for (bindings) |*b| b.name = try a.dupe(u8, b.name);
            server.bindings = bindings;
        }
        return .{ .skills = skills, .servers = servers };
    }
    pub fn disk(self: Extensions, a: std.mem.Allocator) !Extensions {
        const result = try self.clone(a);
        for (result.servers) |*server| inline for (.{ "environment", "headers" }) |key| for (@field(server, key)) |*v| if (v.secret) {
            if (v.value.len != 0 and v.secret_ref == null) return error.UnstoredMcpSecret;
            v.value = "";
        };
        return result;
    }
};
pub fn identifier(value: []const u8) !void {
    try text(value, 128, false);
    for (value) |b| if (!std.ascii.isAlphanumeric(b) and b != '_' and b != '-' and b != '.') return error.InvalidExtensionIdentifier;
}
pub fn text(value: []const u8, limit: usize, empty: bool) !void {
    if ((!empty and std.mem.trim(u8, value, " \t\r\n").len == 0) or value.len > limit or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidExtensionText;
}
fn hex(value: []const u8, len: usize) bool {
    if (value.len != len) return false;
    for (value) |b| if (!std.ascii.isHex(b)) return false;
    return true;
}
