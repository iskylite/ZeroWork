//! Bounded Redfish discovery and schema readers. Every URI is checked before it
//! reaches the transport; no collection member is selected as a write target by
//! position. Parsed response fields borrow their Document.
const std = @import("std");
const svc = @import("../services.zig");
const model = @import("../model.zig");
pub const max_body_bytes = 4 * 1024 * 1024;
pub const max_resources = 1024;
pub const max_collection_members = 256;
pub const Origin = struct {
    authority: []const u8,
    pub fn init(a: std.mem.Allocator, endpoint: model.Endpoint) !Origin {
        try model.validate(.{ .endpoint = endpoint, .username = "validation" });
        var host = endpoint.host;
        if (host[0] == '[') host = host[1 .. host.len - 1];
        host = std.mem.trimEnd(u8, host, ".");
        const lower = try a.dupe(u8, host);
        defer a.free(lower);
        for (lower) |*byte| byte.* = std.ascii.toLower(byte.*);
        const authority = if (std.mem.indexOfScalar(u8, lower, ':') != null)
            try std.fmt.allocPrint(a, "[{s}]:{d}", .{ lower, endpoint.https_port })
        else
            try std.fmt.allocPrint(a, "{s}:{d}", .{ lower, endpoint.https_port });
        return .{ .authority = authority };
    }
};

/// Returns a same-origin HTTP resource target. Encoded path bytes, dot segments,
/// fragments, userinfo, backslashes and protocol-relative links are rejected.
pub fn resourceUri(a: std.mem.Allocator, origin: Origin, resource_link: []const u8) ![]const u8 {
    if (resource_link.len == 0 or resource_link.len > 4096 or std.mem.indexOfAny(u8, resource_link, "\x00 \t\r\n\\#%") != null) return error.InvalidResourceUri;
    for (resource_link) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidResourceUri;
    var path = resource_link;
    if (std.mem.startsWith(u8, resource_link, "https://")) {
        const authority_end = std.mem.indexOfScalarPos(u8, resource_link, 8, '/') orelse return error.InvalidResourceUri;
        const authority = resource_link[8..authority_end];
        if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.CrossOriginResource;
        if (!std.ascii.eqlIgnoreCase(authority, origin.authority)) {
            if (!std.mem.endsWith(u8, origin.authority, ":443") or !std.ascii.eqlIgnoreCase(authority, origin.authority[0 .. origin.authority.len - 4])) return error.CrossOriginResource;
        }
        path = resource_link[authority_end..];
    }
    if (!std.mem.startsWith(u8, path, "/redfish/v1") or (path.len > 11 and path[11] != '/' and path[11] != '?') or std.mem.indexOf(u8, path, "//") != null) return error.InvalidResourceUri;
    const query = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    var segments = std.mem.splitScalar(u8, path[0..query], '/');
    while (segments.next()) |part| if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidResourceUri;
    if (query < path.len) for (path[query + 1 ..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~!$&'()*+,;=:@/?", byte) != null)) return error.InvalidResourceUri;
    };
    return a.dupe(u8, path);
}
pub fn canonicalTarget(a: std.mem.Allocator, origin: Origin, resource_link: []const u8) ![]const u8 {
    const path = try resourceUri(a, origin, resource_link);
    defer a.free(path);
    if (std.mem.indexOfScalar(u8, path, '?') != null) return error.InvalidResourceUri;
    return std.fmt.allocPrint(a, "https://{s}{s}", .{ origin.authority, path });
}
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,
    uri: []const u8,
    etag: ?[]const u8,
    status: u16,
    collected_ms: u64,
    validity: svc.Validity,
    pub fn parse(a: std.mem.Allocator, uri: []const u8, status: u16, body: []const u8, etag: ?[]const u8, now_ms: u64) !Document {
        if (body.len > max_body_bytes) return error.ResponseTooLarge;
        var arena: std.heap.ArenaAllocator = .init(a);
        errdefer arena.deinit();
        const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), if (body.len == 0) "{}" else body, .{ .allocate = .alloc_always, .max_value_len = max_body_bytes });
        if (parsed.value != .object) return error.InvalidRedfishResponse;
        const owned_uri = try arena.allocator().dupe(u8, uri);
        const owned_etag = if (etag) |tag| try arena.allocator().dupe(u8, tag) else null;
        return .{ .arena = arena, .value = parsed.value, .uri = owned_uri, .etag = owned_etag, .status = status, .collected_ms = now_ms, .validity = if (status < 200 or status >= 300) .unavailable else if (hasBodyError(parsed.value)) .partial_with_error else .valid };
    }
    pub fn deinit(self: *Document) void {
        wipeValue(self.value);
        std.crypto.secureZero(u8, @constCast(self.uri));
        if (self.etag) |tag| std.crypto.secureZero(u8, @constCast(tag));
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn evidence(self: Document, present: bool) svc.Evidence {
        return .{ .source_uri = self.uri, .collected_ms = self.collected_ms, .validity = if (present) self.validity else .unavailable };
    }
    pub fn accepted(self: Document) bool {
        return self.status >= 200 and self.status < 300 and !hasBodyError(self.value);
    }
    /// A resource representation may contain object/property diagnostics.
    /// Authentication and action results must continue to use accepted(). An
    /// error-shaped message response, including Success, is never a resource.
    pub fn resourceAvailable(self: Document) bool {
        return self.status >= 200 and self.status < 300 and member(self.value, "error") == null;
    }
    /// DSP0266 9.9.5 separates object annotations from property annotations;
    /// RelatedProperties contains RFC6901 pointers into this payload. An
    /// unscoped root diagnostic stays in evidence(), without invalidating an
    /// independently present property. JSON property names are case-sensitive.
    pub fn fieldEvidence(self: Document, path: []const u8) svc.Evidence {
        var result = self.evidence(false);
        if (!self.resourceAvailable()) return result;
        const pointer = JsonPointer.parse(path) orelse return result;
        const value = pointer.lookup(self.value) orelse return result;
        if (value == .null) return result;
        var scope: [32][]const u8 = undefined;
        var scanned: usize = 0;
        result.validity = if (scopedMessageError(self.value, &pointer, &scope, 0, &scanned)) .partial_with_error else .valid;
        return result;
    }
    pub fn fieldAccepted(self: Document, path: []const u8) bool {
        return self.fieldEvidence(path).validity == .valid;
    }
};

const JsonPointer = struct {
    bytes: [4096]u8 = undefined,
    ends: [32]usize = undefined,
    count: usize = 0,
    fn parse(input: []const u8) ?JsonPointer {
        if (input.len > 4096) return null;
        var decoded: [4096]u8 = undefined;
        var length: usize = 0;
        var index: usize = if (std.mem.startsWith(u8, input, "#")) 1 else 0;
        const fragment = index == 1;
        while (index < input.len) : (index += 1) {
            var byte = input[index];
            if (fragment and byte == '%') {
                if (index + 2 >= input.len) return null;
                const hi = std.fmt.charToDigit(input[index + 1], 16) catch return null;
                const lo = std.fmt.charToDigit(input[index + 2], 16) catch return null;
                byte = hi * 16 + lo;
                index += 2;
            }
            if (byte == 0) return null;
            decoded[length] = byte;
            length += 1;
        }
        var result: JsonPointer = .{};
        if (length == 0) return result;
        if (decoded[0] != '/') return null;
        var tokens = std.mem.splitScalar(u8, decoded[1..length], '/');
        var written: usize = 0;
        while (tokens.next()) |part| {
            if (result.count == result.ends.len) return null;
            index = 0;
            while (index < part.len) : (index += 1) {
                var byte = part[index];
                if (byte == '~') {
                    if (index + 1 == part.len) return null;
                    index += 1;
                    byte = switch (part[index]) {
                        '0' => '~',
                        '1' => '/',
                        else => return null,
                    };
                }
                result.bytes[written] = byte;
                written += 1;
            }
            result.ends[result.count] = written;
            result.count += 1;
        }
        return result;
    }
    fn token(self: *const JsonPointer, index: usize) []const u8 {
        return self.bytes[if (index == 0) 0 else self.ends[index - 1]..self.ends[index]];
    }
    fn lookup(self: *const JsonPointer, root: std.json.Value) ?std.json.Value {
        var value = root;
        for (0..self.count) |i| {
            const key = self.token(i);
            value = switch (value) {
                .object => value.object.get(key) orelse return null,
                .array => blk: {
                    if (key.len == 0 or (key.len > 1 and key[0] == '0')) return null;
                    for (key) |byte| if (!std.ascii.isDigit(byte)) return null;
                    const index = std.fmt.parseInt(usize, key, 10) catch return null;
                    if (index >= value.array.items.len) return null;
                    break :blk value.array.items[index];
                },
                else => return null,
            };
        }
        return value;
    }
    fn overlaps(self: *const JsonPointer, scope: []const []const u8) bool {
        for (0..@min(self.count, scope.len)) |i| if (!std.mem.eql(u8, self.token(i), scope[i])) return false;
        return true;
    }
    fn overlapsPointer(self: *const JsonPointer, other: *const JsonPointer) bool {
        for (0..@min(self.count, other.count)) |i| if (!std.mem.eql(u8, self.token(i), other.token(i))) return false;
        return true;
    }
};
fn annotationAffects(value: std.json.Value, query: *const JsonPointer, scope: []const []const u8, property: bool) bool {
    const local = (scope.len != 0 or query.count == 0) and query.overlaps(scope);
    if (value != .array or value.array.items.len > max_collection_members) return local or scope.len == 0;
    for (value.array.items) |message| {
        if (message != .object) return local or scope.len == 0;
        if (messageOutcome(message) == .success or messageOutcome(message) == .no_operation) continue;
        if (property and local) return true;
        const related = member(message, "RelatedProperties") orelse {
            if (local) return true;
            continue;
        };
        if (related != .array or related.array.items.len > max_collection_members) return local or scope.len == 0;
        if (related.array.items.len == 0 and local) return true;
        for (related.array.items) |item| {
            if (item != .string) return local or scope.len == 0;
            const pointer = JsonPointer.parse(item.string) orelse return local or scope.len == 0;
            if (query.overlapsPointer(&pointer)) return true;
        }
    }
    return false;
}
fn scopedMessageError(value: std.json.Value, query: *const JsonPointer, path: *[32][]const u8, depth: usize, scanned: *usize) bool {
    scanned.* += 1;
    if (scanned.* > 16384) return true;
    if (depth == path.len) return value == .object or value == .array;
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                const suffix = "@Message.ExtendedInfo";
                if (std.mem.endsWith(u8, key, suffix)) {
                    const property = key[0 .. key.len - suffix.len];
                    if (property.len != 0) path[depth] = property;
                    if (annotationAffects(entry.value_ptr.*, query, path[0 .. depth + @as(usize, if (property.len != 0) 1 else 0)], property.len != 0)) return true;
                } else {
                    path[depth] = key;
                    if (scopedMessageError(entry.value_ptr.*, query, path, depth + 1, scanned)) return true;
                }
            }
        },
        .array => |array| for (array.items, 0..) |item, i| {
            var buffer: [20]u8 = undefined;
            path[depth] = std.fmt.bufPrint(&buffer, "{d}", .{i}) catch return true;
            if (scopedMessageError(item, query, path, depth + 1, scanned)) return true;
        },
        else => {},
    }
    return false;
}
fn wipeValue(value: std.json.Value) void {
    switch (value) {
        .string, .number_string => |bytes| std.crypto.secureZero(u8, @constCast(bytes)),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                std.crypto.secureZero(u8, @constCast(entry.key_ptr.*));
                wipeValue(entry.value_ptr.*);
            }
        },
        .array => |array| for (array.items) |item| wipeValue(item),
        else => {},
    }
}
pub fn member(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}
pub fn text(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = member(value, key) orelse return null;
    return if (field == .string) field.string else null;
}
pub fn link(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = member(value, key) orelse return null;
    return text(field, "@odata.id");
}
fn resourceTypeMatches(value: std.json.Value, comptime kind: []const u8) bool {
    if (member(value, "@odata.type") == null) return true;
    const declared = text(value, "@odata.type") orelse return false;
    return std.mem.startsWith(u8, declared, "#" ++ kind ++ ".") and std.mem.endsWith(u8, declared, "." ++ kind);
}
/// A message that reports no change is distinct from success. Callers still
/// need their operation-specific readback before reporting a business result.
pub const MessageOutcome = enum { none, success, no_operation, failure, unrecognized };

/// DSP0266 permits a 2xx response to use the error-shaped message envelope.
/// Inspect the message identifiers and both severity fields, rather than the
/// spelling of the envelope or unrelated resource fields named Severity.
/// Unknown registries/messages cannot provide evidence for a management write.
pub fn bodyMessages(value: std.json.Value) MessageOutcome {
    var result: MessageOutcome = .none;
    if (member(value, "error")) |envelope| {
        if (envelope != .object) return .unrecognized;
        const code = messageSeverityOutcome(envelope, messageIdOutcome(text(envelope, "code") orelse return .unrecognized));
        if (code == .failure or code == .unrecognized) return code;
        if (member(envelope, "@Message.ExtendedInfo")) |info| {
            if (info != .array or info.array.items.len == 0) return .unrecognized;
            result = mergeMessages(code, messageArrayOutcome(info));
        } else result = code;
    }
    return mergeMessages(result, annotatedMessages(value, 0));
}
pub fn hasBodyError(value: std.json.Value) bool {
    return switch (bodyMessages(value)) {
        .failure, .unrecognized => true,
        .none, .success, .no_operation => false,
    };
}
fn mergeMessages(left: MessageOutcome, right: MessageOutcome) MessageOutcome {
    if (left == .failure or right == .failure) return .failure;
    if (left == .unrecognized or right == .unrecognized) return .unrecognized;
    if (left == .no_operation or right == .no_operation) return .no_operation;
    if (left == .success or right == .success) return .success;
    return .none;
}
fn messageIdOutcome(id: []const u8) MessageOutcome {
    var parts = std.mem.splitScalar(u8, id, '.');
    const registry = parts.next() orelse return .unrecognized;
    const major = parts.next() orelse return .unrecognized;
    const minor = parts.next() orelse return .unrecognized;
    const key = parts.next() orelse return .unrecognized;
    if (parts.next() != null or !std.mem.eql(u8, registry, "Base") or !std.mem.eql(u8, major, "1") or minor.len == 0) return .unrecognized;
    for (minor) |byte| if (!std.ascii.isDigit(byte)) return .unrecognized;
    if (std.mem.eql(u8, key, "Success") or std.mem.eql(u8, key, "Created")) return .success;
    if (std.mem.eql(u8, key, "NoOperation")) return .no_operation;
    // Other Base messages may require actions, indicate partial completion or
    // report an error. Their severity alone must never promote them to success.
    return .unrecognized;
}
fn messageOutcome(value: std.json.Value) MessageOutcome {
    if (value != .object) return .unrecognized;
    return messageSeverityOutcome(value, messageIdOutcome(text(value, "MessageId") orelse return .unrecognized));
}
fn messageSeverityOutcome(value: std.json.Value, outcome: MessageOutcome) MessageOutcome {
    var observed_severity: ?[]const u8 = null;
    for ([_][]const u8{ "MessageSeverity", "Severity" }) |key| {
        if (member(value, key)) |field| {
            if (field != .string) return .unrecognized;
            if (observed_severity) |old| if (!std.mem.eql(u8, old, field.string)) return .failure;
            observed_severity = field.string;
            if (!std.mem.eql(u8, field.string, "OK") and !(outcome == .no_operation and std.mem.eql(u8, field.string, "Warning"))) return .failure;
        }
    }
    return outcome;
}
fn messageArrayOutcome(value: std.json.Value) MessageOutcome {
    if (value != .array or value.array.items.len > max_collection_members) return .unrecognized;
    var result: MessageOutcome = .none;
    for (value.array.items) |item| result = mergeMessages(result, messageOutcome(item));
    return result;
}
fn annotatedMessages(value: std.json.Value, depth: usize) MessageOutcome {
    if (depth > 32) return .unrecognized;
    var result: MessageOutcome = .none;
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const outcome = if (std.mem.endsWith(u8, entry.key_ptr.*, "@Message.ExtendedInfo"))
                    messageArrayOutcome(entry.value_ptr.*)
                else
                    annotatedMessages(entry.value_ptr.*, depth + 1);
                result = mergeMessages(result, outcome);
            }
        },
        .array => |array| for (array.items) |item| {
            result = mergeMessages(result, annotatedMessages(item, depth + 1));
        },
        else => {},
    }
    return result;
}
fn stringList(a: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const array = value orelse return null;
    if (array != .array or array.array.items.len > max_collection_members) return null;
    for (array.array.items) |item| if (item != .string or item.string.len > 4096) return null;
    const result = try a.alloc([]const u8, array.array.items.len);
    for (array.array.items, 0..) |item, i| {
        result[i] = item.string;
    }
    return result;
}
pub const Root = struct { systems: []const u8, managers: []const u8, sessions: []const u8 };
pub fn parseRoot(a: std.mem.Allocator, origin: Origin, doc: Document) !Root {
    if (!doc.resourceAvailable() or !doc.fieldAccepted("/Systems") or !doc.fieldAccepted("/Managers") or !doc.fieldAccepted("/SessionService")) return error.InvalidServiceRoot;
    const systems = try resourceUri(a, origin, link(doc.value, "Systems") orelse return error.MissingSystems);
    const managers = try resourceUri(a, origin, link(doc.value, "Managers") orelse return error.MissingManagers);
    const sessions = try resourceUri(a, origin, link(doc.value, "SessionService") orelse return error.MissingSessionService);
    return .{ .systems = systems, .managers = managers, .sessions = sessions };
}
pub const Collection = struct { members: []const []const u8, next: ?[]const u8 };
pub fn parseCollection(a: std.mem.Allocator, origin: Origin, doc: Document) !Collection {
    if (!doc.resourceAvailable() or !doc.fieldAccepted("/Members")) return error.InvalidCollection;
    const array = member(doc.value, "Members") orelse return error.MissingMembers;
    if (array != .array or array.array.items.len > max_collection_members) return error.CollectionTooLarge;
    const result = try a.alloc([]const u8, array.array.items.len);
    for (array.array.items, 0..) |item, i| result[i] = try resourceUri(a, origin, text(item, "@odata.id") orelse return error.InvalidMember);
    for ([_][]const u8{ "Members@odata.nextLink", "@odata.nextLink" }) |key| if (member(doc.value, key) != null) {
        var buffer: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "/{s}", .{key});
        if (!doc.fieldAccepted(path) or text(doc.value, key) == null) return error.InvalidCollection;
    };
    return .{ .members = result, .next = if (text(doc.value, "Members@odata.nextLink") orelse text(doc.value, "@odata.nextLink")) |next| try resourceUri(a, origin, next) else null };
}
pub const ParsedSystem = struct { power: svc.PowerSnapshot, boot: svc.BootSnapshot, action_info: ?[]const u8 = null, boot_options: ?[]const u8 = null, managed_by: []const []const u8 = &.{}, chassis: []const []const u8 = &.{} };
pub fn parseSystem(a: std.mem.Allocator, origin: Origin, doc: Document) !ParsedSystem {
    var identity_available = identityFieldsAvailable(doc) and resourceTypeMatches(doc.value, "ComputerSystem");
    if (identity_available) if (text(doc.value, "@odata.id")) |declared| {
        if (try optionalResourceUri(a, origin, declared)) |uri| {
            defer a.free(uri);
            if (std.mem.indexOfScalar(u8, uri, '?') != null) identity_available = false;
        } else identity_available = false;
    };
    const identity = if (identity_available and doc.fieldAccepted("/UUID")) text(doc.value, "UUID") orelse "" else "";
    const system_identity = if (identity.len != 0) identity else if (identity_available and doc.fieldAccepted("/Id")) text(doc.value, "Id") orelse "" else "";
    var result: ParsedSystem = .{ .power = .{ .system_uri = doc.uri, .system_identity = system_identity, .etag = doc.etag, .resource_evidence = doc.evidence(true) }, .boot = .{ .system_uri = doc.uri, .system_identity = system_identity, .etag = doc.etag, .resource_evidence = doc.evidence(true) } };
    if (!doc.resourceAvailable()) return result;
    if (text(doc.value, "PowerState")) |state| {
        const parsed: svc.PowerState = if (std.mem.eql(u8, state, "On")) .on else if (std.mem.eql(u8, state, "Off")) .off else if (std.mem.eql(u8, state, "PoweringOn")) .powering_on else if (std.mem.eql(u8, state, "PoweringOff")) .powering_off else .unknown;
        result.power.state = .{ .value = parsed, .evidence = typedEvidence(doc, "/PowerState", parsed != .unknown) };
    }
    const reset_time = text(doc.value, "LastResetTime");
    result.power.last_reset_time = .{ .value = reset_time, .evidence = typedEvidence(doc, "/LastResetTime", svc.lastResetTimeMillis(reset_time) != null) };
    if (member(doc.value, "Actions")) |actions| if (member(actions, "#ComputerSystem.Reset")) |reset| {
        if (doc.fieldAccepted("/Actions/#ComputerSystem.Reset/target")) if (text(reset, "target")) |target| {
            result.power.reset_target = try optionalResourceUri(a, origin, target);
        };
        const values = try stringList(a, member(reset, "ResetType@Redfish.AllowableValues"));
        result.power.reset_types = .{ .value = values, .evidence = typedEvidence(doc, "/Actions/#ComputerSystem.Reset/ResetType@Redfish.AllowableValues", values != null) };
        if (doc.fieldAccepted("/Actions/#ComputerSystem.Reset/@Redfish.ActionInfo")) if (text(reset, "@Redfish.ActionInfo")) |info| {
            result.action_info = try optionalResourceUri(a, origin, info);
        };
    };
    if (member(doc.value, "Boot")) |boot| if (boot == .object) {
        result.boot.state = .{ .enabled = text(boot, "BootSourceOverrideEnabled"), .target = text(boot, "BootSourceOverrideTarget"), .mode = text(boot, "BootSourceOverrideMode") };
        const standard_enabled: []const []const u8 = &.{ "Disabled", "Once", "Continuous" };
        const standard_modes: []const []const u8 = &.{ "Legacy", "UEFI" };
        result.boot.enabled_evidence = typedEvidence(doc, "/Boot/BootSourceOverrideEnabled", if (result.boot.state.enabled) |value| svc.contains(standard_enabled, value) else false);
        result.boot.target_evidence = typedEvidence(doc, "/Boot/BootSourceOverrideTarget", if (result.boot.state.target) |value| value.len != 0 and value.len <= 4096 else false);
        result.boot.mode_evidence = typedEvidence(doc, "/Boot/BootSourceOverrideMode", if (result.boot.state.mode) |value| svc.contains(standard_modes, value) else false);
        const enabled_annotation = member(boot, "BootSourceOverrideEnabled@Redfish.AllowableValues");
        const mode_annotation = member(boot, "BootSourceOverrideMode@Redfish.AllowableValues");
        const enabled = if (enabled_annotation != null) try stringList(a, enabled_annotation) else if (result.boot.enabled_evidence.validity == .valid) standard_enabled else null;
        const targets = try stringList(a, member(boot, "BootSourceOverrideTarget@Redfish.AllowableValues"));
        const modes = if (mode_annotation != null) try stringList(a, mode_annotation) else if (result.boot.mode_evidence.validity == .valid) standard_modes else null;
        const order = try stringList(a, member(boot, "BootOrder"));
        const alias = try stringList(a, member(boot, "AliasBootOrder"));
        result.boot.allowed_enabled = .{ .value = enabled, .evidence = if (enabled_annotation != null) typedEvidence(doc, "/Boot/BootSourceOverrideEnabled@Redfish.AllowableValues", enabled != null) else typedEvidence(doc, "/Boot/BootSourceOverrideEnabled", enabled != null) };
        result.boot.allowed_targets = .{ .value = targets, .evidence = typedEvidence(doc, "/Boot/BootSourceOverrideTarget@Redfish.AllowableValues", targets != null) };
        result.boot.allowed_modes = .{ .value = modes, .evidence = if (mode_annotation != null) typedEvidence(doc, "/Boot/BootSourceOverrideMode@Redfish.AllowableValues", modes != null) else typedEvidence(doc, "/Boot/BootSourceOverrideMode", modes != null) };
        result.boot.boot_order = .{ .value = order, .evidence = typedEvidence(doc, "/Boot/BootOrder", order != null) };
        result.boot.alias_boot_order = .{ .value = alias, .evidence = typedEvidence(doc, "/Boot/AliasBootOrder", alias != null) };
        if (doc.fieldAccepted("/Boot/BootOptions")) if (link(boot, "BootOptions")) |options| {
            result.boot_options = try optionalResourceUri(a, origin, options);
        };
        if (member(doc.value, "@Redfish.Settings")) |settings| {
            if (doc.fieldAccepted("/@Redfish.Settings/SettingsObject")) if (link(settings, "SettingsObject")) |uri| {
                result.boot.settings_uri = try optionalResourceUri(a, origin, uri);
            };
            // A SettingsObject does not prove which Boot fields are writable.
        } else result.boot.write_uri = doc.uri;
    };
    if (member(doc.value, "Links")) |links| {
        if (doc.fieldAccepted("/Links/ManagedBy")) result.managed_by = resourceLinks(a, origin, member(links, "ManagedBy")) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => &.{},
        };
        if (doc.fieldAccepted("/Links/Chassis")) result.chassis = resourceLinks(a, origin, member(links, "Chassis")) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => &.{},
        };
    }
    return result;
}
fn typedEvidence(doc: Document, path: []const u8, valid_type: bool) svc.Evidence {
    return if (valid_type) doc.fieldEvidence(path) else doc.evidence(false);
}
fn optionalResourceUri(a: std.mem.Allocator, origin: Origin, uri: []const u8) !?[]const u8 {
    return resourceUri(a, origin, uri) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => null,
    };
}
fn identityFieldsAvailable(doc: Document) bool {
    if (!doc.resourceAvailable()) return false;
    inline for (.{ "@odata.id", "@odata.type", "Id", "UUID" }) |key| {
        if (member(doc.value, key) != null) {
            if (!doc.fieldAccepted("/" ++ key)) return false;
            const value = text(doc.value, key) orelse return false;
            if (std.mem.trim(u8, value, " \t\r\n").len == 0 or value.len > 4096) return false;
        }
    }
    return true;
}
fn resourceLinks(a: std.mem.Allocator, origin: Origin, value: ?std.json.Value) ![]const []const u8 {
    const array = value orelse return &.{};
    if (array != .array or array.array.items.len > max_collection_members) return error.InvalidLinks;
    const result = try a.alloc([]const u8, array.array.items.len);
    for (array.array.items, 0..) |item, i| result[i] = try resourceUri(a, origin, text(item, "@odata.id") orelse return error.InvalidLinks);
    return result;
}
/// This firmware documents a singleton link object; other versions return an
/// array. Normalize only ManagerForServers, preserving strict array schemas for
/// other relationships and the existing same-origin URI validation.
pub fn managerForServers(a: std.mem.Allocator, origin: Origin, value: ?std.json.Value) ![]const []const u8 {
    const links = value orelse return &.{};
    if (links != .object) return resourceLinks(a, origin, links);
    const uri = try resourceUri(a, origin, text(links, "@odata.id") orelse return error.InvalidLinks);
    errdefer a.free(uri);
    const result = try a.alloc([]const u8, 1);
    result[0] = uri;
    return result;
}
pub fn applyActionInfo(a: std.mem.Allocator, snapshot: *svc.PowerSnapshot, doc: Document) !void {
    if (!doc.resourceAvailable()) return;
    const params = member(doc.value, "Parameters") orelse return;
    if (params != .array or params.array.items.len > 32) return;
    for (params.array.items, 0..) |param, index| if (text(param, "Name")) |name| if (std.mem.eql(u8, name, "ResetType")) {
        var name_buffer: [64]u8 = undefined;
        const name_path = try std.fmt.bufPrint(&name_buffer, "/Parameters/{d}/Name", .{index});
        var values_buffer: [64]u8 = undefined;
        const values_path = try std.fmt.bufPrint(&values_buffer, "/Parameters/{d}/AllowableValues", .{index});
        if (!doc.fieldAccepted(name_path) or !doc.fieldAccepted(values_path)) return;
        const values = try stringList(a, member(param, "AllowableValues")) orelse return;
        if (snapshot.reset_types.value) |inline_values| {
            var intersection: std.ArrayList([]const u8) = .empty;
            for (values) |value| if (svc.contains(inline_values, value)) try intersection.append(a, value);
            snapshot.reset_types.value = try intersection.toOwnedSlice(a);
        } else snapshot.reset_types.value = values;
        snapshot.reset_types.evidence = doc.fieldEvidence(values_path);
        return;
    };
}
pub fn secondaryAuth(doc: Document) svc.SecondaryAuth {
    if (!doc.resourceAvailable()) return .unknown;
    var value = member(doc.value, "EnableAuthConfirm");
    var path: []const u8 = "/EnableAuthConfirm";
    if (value == null) if (member(doc.value, "Oem")) |oem| if (member(oem, "Public")) |public| {
        value = member(public, "EnableAuthConfirm");
        path = "/Oem/Public/EnableAuthConfirm";
    };
    if (!doc.fieldAccepted(path)) return .unknown;
    const flag = value orelse return .unknown;
    return if (flag == .bool) (if (flag.bool) .required else .disabled) else .unknown;
}
pub const Task = struct { state: enum { running, completed, failed, unknown }, percent: ?u8 = null };
pub fn parseTask(doc: Document) Task {
    if (!doc.resourceAvailable() or (member(doc.value, "TaskStatus") != null and !doc.fieldAccepted("/TaskStatus")) or (member(doc.value, "TaskState") != null and !doc.fieldAccepted("/TaskState"))) return .{ .state = .failed };
    if (member(doc.value, "TaskStatus") != null) {
        const status = text(doc.value, "TaskStatus") orelse return .{ .state = .failed };
        if (!std.mem.eql(u8, status, "OK")) return .{ .state = .failed };
    }
    const state = text(doc.value, "TaskState") orelse return .{ .state = .unknown };
    if (std.mem.eql(u8, state, "Completed")) return .{ .state = .completed };
    if (std.mem.eql(u8, state, "Exception") or std.mem.eql(u8, state, "Killed") or std.mem.eql(u8, state, "Cancelled") or std.mem.eql(u8, state, "Interrupted")) return .{ .state = .failed };
    if (std.mem.eql(u8, state, "Running") or std.mem.eql(u8, state, "New") or std.mem.eql(u8, state, "Pending") or std.mem.eql(u8, state, "Starting")) return .{ .state = .running };
    return .{ .state = .unknown };
}

pub const ResourceKind = enum { root, systems, managers, system, manager, chassis, action_info, boot_options, boot_option, security, settings, session_service };
pub const Resource = struct { kind: ResourceKind, doc: Document, system_scope: ?[]const u8 = null };
pub const LinkSource = enum {
    none,
    systems,
    managers,
    sessions,
    member,
    members_next,
    odata_next,
    manager_for_servers,
    security,
    public_security,
    action_info,
    boot_options,
    settings,
    chassis,
    pub fn property(self: LinkSource) []const u8 {
        return switch (self) {
            .none => "",
            .systems => "/Systems",
            .managers => "/Managers",
            .sessions => "/SessionService",
            .member => "/Members",
            .members_next => "/Members@odata.nextLink",
            .odata_next => "/@odata.nextLink",
            .manager_for_servers => "/Links/ManagerForServers",
            .security => "/SecurityService",
            .public_security => "/Oem/Public/SecurityService",
            .action_info => "/Actions/#ComputerSystem.Reset/@Redfish.ActionInfo",
            .boot_options => "/Boot/BootOptions",
            .settings => "/@Redfish.Settings/SettingsObject",
            .chassis => "/Links/Chassis",
        };
    }
};
pub const ReadRequest = struct { uri: []const u8, kind: ResourceKind, system_scope: ?[]const u8 = null, source_uri: ?[]const u8 = null, source: LinkSource = .none };
pub const ResourceAssociation = struct {
    system_uri: []const u8,
    manager_uri: []const u8,
    chassis_uri: []const u8,
    root_evidence: svc.Evidence,
    chassis_evidence: svc.Evidence,
};
pub const Discovery = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    origin: Origin,
    queue: std.ArrayList(ReadRequest) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    outstanding: std.ArrayList(ReadRequest) = .empty,
    cursor: usize = 0,
    mapping_system: ?[]const u8 = null,
    mapping_manager: ?[]const u8 = null,
    /// Standard management targets have their own proof. A verified System
    /// does not establish which server an OEM video channel displays.
    management_system: ?[]const u8 = null,
    management_manager: ?[]const u8 = null,
    /// This OEM navigation property is enabled only by the exact reviewed
    /// firmware profile, never inferred from an arbitrary Public namespace.
    oem_public_security_service: bool = false,
    /// Reviewed Root.Public IDs can corroborate a read source through standard
    /// Chassis links. Property validity and write authorization stay separate.
    oem_public_resource_association: bool = false,
    boot_write_targets: std.ArrayList(struct { system_uri: []const u8, write_uri: []const u8 }) = .empty,
    pub fn init(a: std.mem.Allocator, endpoint: model.Endpoint) !Discovery {
        var self: Discovery = .{ .arena = .init(a), .backing = a, .origin = undefined };
        errdefer self.arena.deinit();
        self.origin = try Origin.init(self.arena.allocator(), endpoint);
        try self.outstanding.ensureTotalCapacity(self.arena.allocator(), 8);
        try self.schedule("/redfish/v1/", .root);
        return self;
    }
    pub fn deinit(self: *Discovery) void {
        for (self.resources.items) |*resource| resource.doc.deinit();
        self.resources.deinit(self.backing);
        self.arena.deinit();
        self.* = undefined;
    }
    fn schedule(self: *Discovery, uri: []const u8, kind: ResourceKind) !void {
        return self.scheduleScoped(uri, kind, null);
    }
    fn scheduleScoped(self: *Discovery, uri: []const u8, kind: ResourceKind, system_scope: ?[]const u8) !void {
        return self.scheduleFrom(uri, kind, system_scope, null, .none);
    }
    fn scheduleFrom(self: *Discovery, uri: []const u8, kind: ResourceKind, system_scope: ?[]const u8, source_uri: ?[]const u8, source: LinkSource) !void {
        const checked = try resourceUri(self.arena.allocator(), self.origin, uri);
        for (self.queue.items) |existing| if (std.mem.eql(u8, existing.uri, checked)) return;
        if (self.queue.items.len >= max_resources) return error.DiscoveryLimit;
        try self.queue.append(self.arena.allocator(), .{ .uri = checked, .kind = kind, .system_scope = system_scope, .source_uri = source_uri, .source = source });
    }
    pub fn next(self: *Discovery) ?ReadRequest {
        if (self.cursor == self.queue.items.len or self.outstanding.items.len >= 8) return null;
        const result = self.queue.items[self.cursor];
        self.cursor += 1;
        self.outstanding.appendAssumeCapacity(result);
        return result;
    }
    /// Firmware proof is a console prerequisite; unrelated management reads
    /// must not precede it just because Root listed Systems first. Reordering
    /// unissued requests preserves the ordinary outstanding/completion gate.
    pub fn nextOfKind(self: *Discovery, kind: ResourceKind) ?ReadRequest {
        if (self.outstanding.items.len >= 8) return null;
        for (self.queue.items[self.cursor..], self.cursor..) |request, index| if (request.kind == kind) {
            std.mem.swap(ReadRequest, &self.queue.items[self.cursor], &self.queue.items[index]);
            return self.next();
        };
        return null;
    }
    pub fn ingest(self: *Discovery, request: ReadRequest, status: u16, body: []const u8, etag: ?[]const u8, now_ms: u64) !void {
        var outstanding_index: ?usize = null;
        for (self.outstanding.items, 0..) |pending, i| if (pending.kind == request.kind and std.mem.eql(u8, pending.uri, request.uri)) {
            outstanding_index = i;
            break;
        };
        _ = self.outstanding.swapRemove(outstanding_index orelse return error.StaleDiscoveryCompletion);
        const a = self.arena.allocator();
        var doc = Document.parse(self.backing, request.uri, status, body, etag, now_ms) catch |err| missing_link: {
            // A missing, advertised alias must not abort the collection reads
            // merely because its 404 body is HTML or not a Redfish object.
            if (err == error.OutOfMemory or body.len > max_body_bytes or status != 404 or request.source != .manager_for_servers) return err;
            break :missing_link try Document.parse(self.backing, request.uri, status, "{}", etag, now_ms);
        };
        errdefer doc.deinit();
        if (doc.resourceAvailable()) switch (request.kind) {
            .root => {
                const root = try parseRoot(a, self.origin, doc);
                try self.scheduleFrom(root.systems, .systems, null, doc.uri, .systems);
                try self.scheduleFrom(root.managers, .managers, null, doc.uri, .managers);
                try self.scheduleFrom(root.sessions, .session_service, null, doc.uri, .sessions);
            },
            .systems, .managers, .boot_options => collection: {
                if (!doc.fieldAccepted("/Members")) break :collection;
                const collection = try parseCollection(a, self.origin, doc);
                const kind: ResourceKind = switch (request.kind) {
                    .systems => .system,
                    .managers => .manager,
                    else => .boot_option,
                };
                for (collection.members) |uri| try self.scheduleFrom(uri, kind, request.system_scope, doc.uri, .member);
                if (collection.next) |next_uri| {
                    for (self.queue.items[0..self.cursor]) |existing| if (std.mem.eql(u8, existing.uri, next_uri)) return error.PaginationCycle;
                    try self.scheduleFrom(next_uri, request.kind, request.system_scope, doc.uri, if (member(doc.value, "Members@odata.nextLink") != null) .members_next else .odata_next);
                }
            },
            .system => {
                const parsed_system = try parseSystem(a, self.origin, doc);
                if (parsed_system.action_info) |uri| try self.scheduleFrom(uri, .action_info, null, doc.uri, .action_info);
                if (parsed_system.boot_options) |uri| try self.scheduleFrom(uri, .boot_options, doc.uri, doc.uri, .boot_options);
                if (parsed_system.boot.settings_uri) |uri| try self.scheduleFrom(uri, .settings, doc.uri, doc.uri, .settings);
                for (parsed_system.chassis) |uri| try self.scheduleFrom(uri, .chassis, null, doc.uri, .chassis);
            },
            .manager => {
                // The manager can identify the canonical ComputerSystem even
                // when Systems collection members use another resource alias.
                // Follow only validated same-origin links; proveKvmMapping
                // still requires valid System identity and a
                // reciprocal ManagedBy relationship before publishing reads.
                if (doc.fieldAccepted("/Links/ManagerForServers")) if (member(doc.value, "Links")) |links| {
                    const managed = managerForServers(a, self.origin, member(links, "ManagerForServers")) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => &.{},
                    };
                    for (managed) |uri| try self.scheduleFrom(uri, .system, null, doc.uri, .manager_for_servers);
                };
                if (self.managerSecurityLink(doc)) |uri| if (try optionalResourceUri(a, self.origin, uri)) |checked| try self.scheduleFrom(checked, .security, null, doc.uri, if (doc.fieldAccepted("/SecurityService") and link(doc.value, "SecurityService") != null) .security else .public_security);
            },
            else => {},
        };
        try self.resources.append(self.backing, .{ .kind = request.kind, .doc = doc, .system_scope = request.system_scope });
    }
    pub fn find(self: *const Discovery, uri: []const u8) ?*const Document {
        for (self.resources.items) |*resource| if (std.mem.eql(u8, resource.doc.uri, uri)) return &resource.doc;
        return null;
    }
    fn managerSecurityLink(self: *const Discovery, doc: Document) ?[]const u8 {
        if (doc.fieldAccepted("/SecurityService")) if (link(doc.value, "SecurityService")) |uri| return uri;
        if (!self.oem_public_security_service) return null;
        if (!doc.fieldAccepted("/Oem/Public/SecurityService")) return null;
        const oem = member(doc.value, "Oem") orelse return null;
        const public = member(oem, "Public") orelse return null;
        return link(public, "SecurityService");
    }
    /// A partial representation can retain independent property evidence and
    /// its object diagnostic. An error envelope or an uncertain resource
    /// identity is not a resource representation for this purpose.
    pub fn partialSystemRepresentation(self: *const Discovery, doc: Document) bool {
        if (doc.validity != .partial_with_error or !identityFieldsAvailable(doc) or member(doc.value, "@odata.id") == null or
            member(doc.value, "@odata.type") == null or !resourceTypeMatches(doc.value, "ComputerSystem")) return false;
        const canonical = self.documentIdentityUri(doc) catch return false;
        defer self.backing.free(canonical);
        return std.mem.eql(u8, canonical, doc.uri);
    }
    /// The exact reviewed OEM IDs identify candidates; accepted standard Root
    /// and Chassis links corroborate the relationship. System property errors
    /// are retained and cannot become valid evidence through this association.
    /// In particular, no ManagerForServers alias or /kvm/0 binding is invented.
    pub fn proveResourceAssociation(self: *Discovery) !ResourceAssociation {
        if (!self.oem_public_resource_association or self.cursor != self.queue.items.len or self.outstanding.items.len != 0) return error.ResourceAssociationUnverified;
        const root = self.find("/redfish/v1/") orelse return error.ResourceAssociationUnverified;
        if (!root.resourceAvailable() or !root.fieldAccepted("/Oem/Public/SystemId") or !root.fieldAccepted("/Oem/Public/ManagerId") or !root.fieldAccepted("/Oem/Public/ChassisId") or !root.fieldAccepted("/Links/ManagerProvidingService")) return error.ResourceAssociationUnverified;
        const public = member(member(root.value, "Oem") orelse return error.ResourceAssociationUnverified, "Public") orelse return error.ResourceAssociationUnverified;
        const system_id = text(public, "SystemId") orelse return error.ResourceAssociationUnverified;
        const manager_id = text(public, "ManagerId") orelse return error.ResourceAssociationUnverified;
        const chassis_id = text(public, "ChassisId") orelse return error.ResourceAssociationUnverified;
        if (system_id.len == 0 or manager_id.len == 0 or chassis_id.len == 0) return error.ResourceAssociationUnverified;
        const root_links = member(root.value, "Links") orelse return error.ResourceAssociationUnverified;
        const manager_uri = try resourceUri(self.arena.allocator(), self.origin, link(root_links, "ManagerProvidingService") orelse return error.ResourceAssociationUnverified);
        const manager = self.find(manager_uri) orelse return error.ResourceAssociationUnverified;
        if (!identityFieldsAvailable(manager.*) or member(manager.value, "@odata.type") == null or !resourceTypeMatches(manager.value, "Manager") or !svc.optionalEqual(text(manager.value, "Id"), manager_id)) return error.ResourceAssociationUnverified;
        const manager_canonical = try self.documentIdentityUri(manager.*);
        defer self.backing.free(manager_canonical);
        if (!std.mem.eql(u8, manager_canonical, manager_uri)) return error.ResourceAssociationUnverified;
        var selected: ?*const Document = null;
        for (self.resources.items) |*resource| {
            if (resource.kind != .system or !svc.optionalEqual(text(resource.doc.value, "Id"), system_id)) continue;
            if (!identityFieldsAvailable(resource.doc) or !try self.collectionContainsSystem(resource.doc.uri)) return error.ResourceAssociationUnverified;
            if (selected != null) return error.ResourceAssociationAmbiguous;
            selected = &resource.doc;
        }
        const system_doc = selected orelse return error.ResourceAssociationUnverified;
        if (member(system_doc.value, "@odata.type") == null) return error.ResourceAssociationUnverified;
        try self.validateSystemIdentity(system_doc.*);
        const system_canonical = try self.documentIdentityUri(system_doc.*);
        defer self.backing.free(system_canonical);
        if (!std.mem.eql(u8, system_canonical, system_doc.uri)) return error.ResourceAssociationUnverified;
        const parsed = try parseSystem(self.arena.allocator(), self.origin, system_doc.*);
        if (!svc.contains(parsed.managed_by, manager_uri)) return error.ResourceAssociationUnverified;
        var matched: ?*const Document = null;
        for (parsed.chassis) |uri| {
            const chassis = self.find(uri) orelse continue;
            if (!svc.optionalEqual(text(chassis.value, "Id"), chassis_id)) continue;
            if (!identityFieldsAvailable(chassis.*) or member(chassis.value, "@odata.type") == null or !resourceTypeMatches(chassis.value, "Chassis") or !chassis.fieldAccepted("/Links/ComputerSystems") or !chassis.fieldAccepted("/Links/ManagedBy")) return error.ResourceAssociationUnverified;
            const canonical = try self.documentIdentityUri(chassis.*);
            defer self.backing.free(canonical);
            if (!std.mem.eql(u8, canonical, uri)) return error.ResourceAssociationUnverified;
            const links = member(chassis.value, "Links") orelse return error.ResourceAssociationUnverified;
            const systems = try resourceLinks(self.arena.allocator(), self.origin, member(links, "ComputerSystems"));
            const managers = try resourceLinks(self.arena.allocator(), self.origin, member(links, "ManagedBy"));
            if (!svc.contains(systems, system_doc.uri) or !svc.contains(managers, manager_uri)) return error.ResourceAssociationUnverified;
            if (matched != null) return error.ResourceAssociationAmbiguous;
            matched = chassis;
        }
        const chassis = matched orelse return error.ResourceAssociationUnverified;
        return .{ .system_uri = system_doc.uri, .manager_uri = manager.uri, .chassis_uri = chassis.uri, .root_evidence = root.evidence(true), .chassis_evidence = chassis.evidence(true) };
    }
    fn collectionContainsSystem(self: *Discovery, uri: []const u8) !bool {
        var found = false;
        for (self.resources.items) |resource| if (resource.kind == .systems) {
            if (!resource.doc.resourceAvailable() or !resource.doc.fieldAccepted("/Members")) return false;
            const collection = try parseCollection(self.arena.allocator(), self.origin, resource.doc);
            if (svc.contains(collection.members, uri)) found = true;
        };
        return found;
    }
    /// Bind standard management independently of the OEM KVM channel. The
    /// service Manager and complete collections must be trustworthy; multiple
    /// Systems require an explicit reciprocal or reviewed resource selection.
    pub fn proveManagementTarget(self: *Discovery) !void {
        self.management_system = null;
        self.management_manager = null;
        if (self.cursor != self.queue.items.len or self.outstanding.items.len != 0) return error.ManagementTargetUnverified;
        const root = self.find("/redfish/v1/") orelse return error.ManagementTargetUnverified;
        if (!root.resourceAvailable()) return error.ManagementTargetUnverified;
        var manager_uri: ?[]const u8 = null;
        if (member(root.value, "Links")) |links| if (member(links, "ManagerProvidingService") != null) {
            if (!root.fieldAccepted("/Links/ManagerProvidingService")) return error.ManagementTargetUnverified;
            manager_uri = try resourceUri(self.arena.allocator(), self.origin, link(links, "ManagerProvidingService") orelse return error.ManagementTargetUnverified);
        };
        var managers: usize = 0;
        var manager_member: ?[]const u8 = null;
        var service_manager_found = false;
        var systems: usize = 0;
        var system_uri: ?[]const u8 = null;
        for (self.resources.items) |resource| {
            if (resource.kind != .systems and resource.kind != .managers) continue;
            if (!resource.doc.resourceAvailable() or !resource.doc.fieldAccepted("/Members")) return error.ManagementTargetUnverified;
            const collection = try parseCollection(self.arena.allocator(), self.origin, resource.doc);
            for (collection.members) |uri| {
                if (resource.kind == .managers) {
                    managers += 1;
                    manager_member = uri;
                    if (manager_uri) |service_uri| if (std.mem.eql(u8, service_uri, uri)) {
                        service_manager_found = true;
                    };
                } else {
                    systems += 1;
                    system_uri = uri;
                }
            }
        }
        if (systems == 0 or managers == 0) return error.ManagementTargetUnverified;
        if (manager_uri == null) {
            if (managers != 1) return error.ManagementTargetAmbiguous;
            manager_uri = manager_member;
        } else if (!service_manager_found) return error.ManagementTargetUnverified;
        const manager = self.find(manager_uri.?) orelse return error.ManagementTargetUnverified;
        if (!identityFieldsAvailable(manager.*) or !resourceTypeMatches(manager.value, "Manager") or std.mem.trim(u8, text(manager.value, "Id") orelse "", " \t\r\n").len == 0) return error.ManagementTargetUnverified;
        const manager_identity = try self.documentIdentityUri(manager.*);
        defer self.backing.free(manager_identity);
        if (!std.mem.eql(u8, manager_identity, manager.uri)) return error.ManagementTargetUnverified;

        if (self.proveResourceAssociation()) |association| {
            if (!std.mem.eql(u8, association.manager_uri, manager.uri)) return error.ManagementTargetUnverified;
            return self.bindManagementTarget(association.system_uri, manager.uri);
        } else |_| {}
        if (member(manager.value, "Links")) |links| if (member(links, "ManagerForServers") != null and !manager.fieldAccepted("/Links/ManagerForServers")) return error.ManagementTargetUnverified;
        const managed = if (member(manager.value, "Links")) |links|
            try managerForServers(self.arena.allocator(), self.origin, member(links, "ManagerForServers"))
        else
            &.{};
        if (managed.len == 1 and try self.collectionIdentifiesSystem(managed[0])) {
            // This relationship can select one resource from a multi-system
            // collection without depending on a particular video channel.
            return self.bindManagementTarget(managed[0], manager.uri);
        }
        if (systems != 1) return error.ManagementTargetAmbiguous;
        // An unavailable forward link is not an alias declaration. The unique
        // collection member can still identify management through ManagedBy;
        // a conflicting, accepted forward resource cannot be ignored.
        for (managed) |uri| if (self.find(uri)) |forward| if (forward.resourceAvailable()) {
            const canonical = try self.documentIdentityUri(forward.*);
            defer self.backing.free(canonical);
            if (!std.mem.eql(u8, canonical, system_uri.?)) return error.ManagementTargetAmbiguous;
        };
        return self.bindManagementTarget(system_uri.?, manager.uri);
    }
    fn collectionIdentifiesSystem(self: *Discovery, uri: []const u8) !bool {
        for (self.resources.items) |resource| if (resource.kind == .systems) {
            if (!resource.doc.resourceAvailable() or !resource.doc.fieldAccepted("/Members")) return false;
            const collection = try parseCollection(self.arena.allocator(), self.origin, resource.doc);
            for (collection.members) |member_uri| {
                if (std.mem.eql(u8, member_uri, uri)) return true;
                const doc = self.find(member_uri) orelse continue;
                if (!identityFieldsAvailable(doc.*) or !resourceTypeMatches(doc.value, "ComputerSystem")) continue;
                const canonical = self.documentIdentityUri(doc.*) catch continue;
                defer self.backing.free(canonical);
                if (std.mem.eql(u8, canonical, uri)) return true;
            }
        };
        return false;
    }
    fn bindManagementTarget(self: *Discovery, system_uri: []const u8, manager_uri: []const u8) !void {
        const doc = self.find(system_uri) orelse return error.ManagementTargetUnverified;
        if (!identityFieldsAvailable(doc.*)) return error.ManagementTargetUnverified;
        const canonical = try self.documentIdentityUri(doc.*);
        defer self.backing.free(canonical);
        if (!std.mem.eql(u8, canonical, doc.uri)) return error.ManagementTargetUnverified;
        try self.validateSystemIdentity(doc.*);
        const parsed = try parseSystem(self.arena.allocator(), self.origin, doc.*);
        if (std.mem.trim(u8, parsed.power.system_identity, " \t\r\n").len == 0 or !svc.contains(parsed.managed_by, manager_uri)) return error.ManagementTargetUnverified;
        self.management_system = doc.uri;
        self.management_manager = manager_uri;
    }
    /// The profile must independently prove this manager owns the KVM channel.
    /// Relationship links then have to identify exactly one ComputerSystem.
    pub fn proveKvmMapping(self: *Discovery, manager_uri: []const u8, channel: []const u8, profile_evidence_verified: bool) !void {
        self.mapping_system = null;
        self.mapping_manager = null;
        if (!profile_evidence_verified or !std.mem.eql(u8, channel, "/kvm/0")) return error.MappingUnverified;
        const manager = self.find(manager_uri) orelse return error.MappingUnverified;
        if (!identityFieldsAvailable(manager.*) or !manager.fieldAccepted("/Links/ManagerForServers")) return error.MappingUnverified;
        if (!resourceTypeMatches(manager.value, "Manager")) return error.MappingUnverified;
        const manager_identity = self.documentIdentityUri(manager.*) catch return error.MappingUnverified;
        defer self.backing.free(manager_identity);
        const links = member(manager.value, "Links") orelse return error.MappingUnverified;
        const managed = try managerForServers(self.arena.allocator(), self.origin, member(links, "ManagerForServers"));
        if (managed.len != 1) return error.MappingAmbiguous;
        const system_doc = self.find(managed[0]) orelse return error.MappingUnverified;
        const parsed_system = try parseSystem(self.arena.allocator(), self.origin, system_doc.*);
        if (!identityFieldsAvailable(system_doc.*) or
            (!svc.contains(parsed_system.managed_by, manager_uri) and !svc.contains(parsed_system.managed_by, manager_identity)) or
            std.mem.trim(u8, parsed_system.power.system_identity, " \t\r\n").len == 0) return error.MappingUnverified;
        try self.validateSystemIdentity(system_doc.*);
        self.mapping_system = system_doc.uri;
        self.mapping_manager = try self.arena.allocator().dupe(u8, manager_uri);
    }
    fn documentIdentityUri(self: *const Discovery, doc: Document) ![]const u8 {
        if (!identityFieldsAvailable(doc)) return error.MappingUnverified;
        const declared = if (member(doc.value, "@odata.id") != null)
            text(doc.value, "@odata.id") orelse return error.MappingUnverified
        else
            doc.uri;
        const uri = try resourceUri(self.backing, self.origin, declared);
        errdefer self.backing.free(uri);
        if (std.mem.indexOfScalar(u8, uri, '?') != null) return error.MappingUnverified;
        return uri;
    }
    /// A UUID is corroboration, never an alias declaration. Distinct resource
    /// identities with the same UUID are ambiguous; aliases that explicitly
    /// share @odata.id must not contradict each other's UUID or collection Id.
    fn validateSystemIdentity(self: *const Discovery, selected: Document) !void {
        if (!identityFieldsAvailable(selected) or !resourceTypeMatches(selected.value, "ComputerSystem")) return error.MappingUnverified;
        const selected_uri = self.documentIdentityUri(selected) catch return error.MappingUnverified;
        defer self.backing.free(selected_uri);
        const selected_uuid = text(selected.value, "UUID");
        for (self.resources.items) |resource| {
            if (resource.kind != .system or resource.doc.validity == .unavailable or std.mem.eql(u8, resource.doc.uri, selected.uri)) continue;
            const other_uuid = text(resource.doc.value, "UUID");
            const same_uuid = selected_uuid != null and other_uuid != null and selected_uuid.?.len != 0 and std.ascii.eqlIgnoreCase(selected_uuid.?, other_uuid.?);
            const other_uri = self.documentIdentityUri(resource.doc) catch {
                if (same_uuid) return error.MappingAmbiguous;
                continue;
            };
            defer self.backing.free(other_uri);
            if (!std.mem.eql(u8, selected_uri, other_uri)) {
                if (same_uuid) return error.MappingAmbiguous;
                continue;
            }
            if (!resourceTypeMatches(resource.doc.value, "ComputerSystem")) return error.MappingAmbiguous;
            if (selected_uuid != null and other_uuid != null and !std.ascii.eqlIgnoreCase(selected_uuid.?, other_uuid.?)) return error.MappingAmbiguous;
            if (text(selected.value, "Id")) |selected_id| if (text(resource.doc.value, "Id")) |other_id| {
                if (!std.mem.eql(u8, selected_id, other_id)) return error.MappingAmbiguous;
            };
        }
    }
    pub fn system(self: *Discovery, uri: []const u8, capability: svc.Capability) !ParsedSystem {
        const doc = self.find(uri) orelse return error.ResourceUnavailable;
        const a = self.arena.allocator();
        var result = try parseSystem(a, self.origin, doc.*);
        if (result.action_info) |info| if (self.find(info)) |action_doc| try applyActionInfo(a, &result.power, action_doc.*);
        var cap = capability;
        cap.system_mapping_verified = self.management_system != null and std.mem.eql(u8, self.management_system.?, uri);
        if (!cap.system_mapping_verified) {
            cap.write_granted = false;
            cap.write_requestable = false;
        }
        cap.secondary_auth = .unknown;
        cap.secondary_auth_evidence = .{};
        if (if (cap.system_mapping_verified) self.management_manager else null) |manager_uri| if (self.find(manager_uri)) |manager| if (self.managerSecurityLink(manager.*)) |security_link| if (try optionalResourceUri(a, self.origin, security_link)) |security_uri| {
            if (self.find(security_uri)) |security| {
                cap.secondary_auth = secondaryAuth(security.*);
                cap.secondary_auth_evidence = if (cap.secondary_auth == .unknown) security.evidence(false) else security.fieldEvidence(if (member(security.value, "EnableAuthConfirm") != null) "/EnableAuthConfirm" else "/Oem/Public/EnableAuthConfirm");
            }
        };
        result.power.capability = cap;
        result.boot.capability = cap;
        if (result.boot.settings_uri) |settings_uri| if (self.find(settings_uri)) |pending| {
            const parsed_pending = try parseSystem(a, self.origin, pending.*);
            const state: svc.BootState = .{
                .enabled = if (parsed_pending.boot.enabled_evidence.validity == .valid) parsed_pending.boot.state.enabled else null,
                .target = if (parsed_pending.boot.target_evidence.validity == .valid) parsed_pending.boot.state.target else null,
                .mode = if (parsed_pending.boot.mode_evidence.validity == .valid) parsed_pending.boot.state.mode else null,
            };
            if (state.enabled != null or state.target != null or state.mode != null) result.boot.pending = state;
        };
        for (self.boot_write_targets.items) |target| if (std.mem.eql(u8, target.system_uri, uri)) {
            result.boot.write_uri = target.write_uri;
            result.boot.etag = (self.find(target.write_uri) orelse return error.ResourceUnavailable).etag;
            break;
        };
        var options: std.ArrayList(svc.BootOption) = .empty;
        for (self.resources.items) |resource| if (resource.kind == .boot_option and resource.doc.resourceAvailable() and svc.optionalEqual(resource.system_scope, uri)) {
            const reference = text(resource.doc.value, "BootOptionReference") orelse continue;
            if (reference.len == 0 or reference.len > 4096) continue;
            var duplicate = false;
            for (options.items) |old| if (std.mem.eql(u8, old.reference, reference)) {
                duplicate = true;
                break;
            };
            if (!duplicate) {
                if (options.items.len >= max_collection_members) return error.CollectionTooLarge;
                const enabled = member(resource.doc.value, "BootOptionEnabled");
                try options.append(a, .{ .reference = reference, .id = if (resource.doc.fieldAccepted("/Id")) text(resource.doc.value, "Id") orelse resource.doc.uri else resource.doc.uri, .name = if (resource.doc.fieldAccepted("/DisplayName")) text(resource.doc.value, "DisplayName") else null, .enabled = if (enabled != null and enabled.? == .bool and resource.doc.fieldAccepted("/BootOptionEnabled")) enabled.?.bool else null, .evidence = resource.doc.fieldEvidence("/BootOptionReference") });
            }
        };
        result.boot.options = try options.toOwnedSlice(a);
        return result;
    }
    /// A firmware/profile can explicitly establish which discovered resource
    /// owns the Boot fields. Discovery never tries both current and Settings.
    pub fn confirmBootWriteTarget(self: *Discovery, system_uri: []const u8, write_uri: []const u8, field_mapping_verified: bool) !void {
        if (!field_mapping_verified) return error.BootWriteTargetUnverified;
        const system_doc = self.find(system_uri) orelse return error.ResourceUnavailable;
        const parsed_system = try parseSystem(self.arena.allocator(), self.origin, system_doc.*);
        const target = try resourceUri(self.arena.allocator(), self.origin, write_uri);
        if (!identityFieldsAvailable(system_doc.*) or (!std.mem.eql(u8, target, system_uri) and !svc.optionalEqual(parsed_system.boot.settings_uri, target))) return error.BootWriteTargetUnverified;
        const target_doc = self.find(target) orelse return error.ResourceUnavailable;
        if (!target_doc.resourceAvailable() or (member(target_doc.value, "Boot") orelse return error.BootWriteTargetUnverified) != .object) return error.BootWriteTargetUnverified;
        for (self.boot_write_targets.items) |*entry| if (std.mem.eql(u8, entry.system_uri, system_uri)) {
            entry.write_uri = target;
            return;
        };
        try self.boot_write_targets.append(self.arena.allocator(), .{ .system_uri = system_doc.uri, .write_uri = target });
    }
};
