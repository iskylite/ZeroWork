//! Shared protocol endpoint resolution, independent of transport and settings.
const std = @import("std");
const registry = @import("registry.zig");

/// Accept a provider base URL as well as an explicit protocol endpoint.
/// Preserve custom prefixes and explicit endpoints; insert suffixes before queries.
pub fn chatEndpoint(allocator: std.mem.Allocator, kind: registry.Kind, endpoint: []const u8) ![]u8 {
    return apiEndpoint(allocator, kind, endpoint, .chat);
}

pub fn modelsEndpoint(allocator: std.mem.Allocator, kind: registry.Kind, endpoint: []const u8) ![]u8 {
    return apiEndpoint(allocator, kind, endpoint, .models);
}

pub fn ollamaShowEndpoint(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    return apiEndpoint(allocator, .ollama, endpoint, .show);
}

fn apiEndpoint(allocator: std.mem.Allocator, kind: registry.Kind, endpoint: []const u8, target: enum { chat, models, show }) ![]u8 {
    const uri = try std.Uri.parse(endpoint);
    if (uri.fragment != null) return allocator.dupe(u8, endpoint);
    var path = std.mem.trimEnd(u8, switch (uri.path) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    }, "/");
    const query_at = std.mem.indexOfScalar(u8, endpoint, '?') orelse endpoint.len;
    const query = endpoint[query_at..];
    var base = std.mem.trimEnd(u8, endpoint[0..query_at], "/");
    const chat_suffix = switch (kind) {
        .openai_compat => "/chat/completions",
        .anthropic => "/messages",
        .ollama => "/chat",
    };
    const suffix = switch (target) {
        .chat => chat_suffix,
        .models => if (kind == .ollama) "/tags" else "/models",
        .show => "/show",
    };
    // An explicit chat endpoint establishes its own protocol base, including
    // gateways whose complete endpoint deliberately omits /v1 or /api.
    // Also recognize the requested resource so repeated resolution is stable.
    const explicit_suffix = if (std.mem.endsWith(u8, path, chat_suffix)) chat_suffix else if (std.mem.endsWith(u8, path, suffix)) suffix else "";
    if (explicit_suffix.len != 0) {
        base = base[0 .. base.len - explicit_suffix.len];
        path = path[0 .. path.len - explicit_suffix.len];
    }
    const version = if (kind == .ollama) "/api" else "/v1";
    // Keep the existing bare-host OpenAI /v1 convenience. Custom OpenAI base
    // paths are used verbatim; Anthropic and Ollama include their route prefix.
    const needs_version = explicit_suffix.len == 0 and switch (kind) {
        .openai_compat => path.len == 0,
        .anthropic, .ollama => !std.mem.endsWith(u8, path, version),
    };
    return std.mem.concat(allocator, u8, &.{ base, if (needs_version) version else "", suffix, query });
}

test "Ollama model metadata routes preserve base paths and queries" {
    const a = std.testing.allocator;
    for ([_][2][]const u8{
        .{ "http://localhost:11434", "http://localhost:11434/api/show" },
        .{ "http://localhost:11434/tenant/proxy/?x=1", "http://localhost:11434/tenant/proxy/api/show?x=1" },
        .{ "http://localhost:11434/tenant/proxy/api/?x=1", "http://localhost:11434/tenant/proxy/api/show?x=1" },
        .{ "http://localhost:11434/tenant/proxy/api/chat/?x=1", "http://localhost:11434/tenant/proxy/api/show?x=1" },
        .{ "http://localhost:11434/custom/chat?x=1", "http://localhost:11434/custom/show?x=1" },
    }) |pair| {
        const actual = try ollamaShowEndpoint(a, pair[0]);
        defer a.free(actual);
        try std.testing.expectEqualStrings(pair[1], actual);
    }
}
