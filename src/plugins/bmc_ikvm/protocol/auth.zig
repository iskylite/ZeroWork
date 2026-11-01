//! WEB and OEM KVM authentication domains are deliberately separate types.
//! Public-key/profile evidence is mandatory; historical prose cannot enable a
//! production authentication attempt. All auth/session text owns wipeable memory.
const std = @import("std");
const redfish = @import("redfish.zig");
const identity = @import("../../../host/identity.zig");
const svc = @import("../services.zig");
pub const Secret = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    pub fn init(a: std.mem.Allocator, value: []const u8) !Secret {
        return .{ .allocator = a, .bytes = try a.dupe(u8, value) };
    }
    pub fn clear(self: *Secret) void {
        std.crypto.secureZero(u8, self.bytes);
    }
    pub fn deinit(self: *Secret) void {
        self.clear();
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};
pub const Evidence = struct {
    profile_id: []const u8 = "",
    firmware: []const u8 = "",
    public_key_pem: []const u8 = "",
    public_key_sha256: [32]u8 = @splat(0),
    source_uri: []const u8 = "",
    verified: bool = false,
    web_headers_verified: bool = false,
    kvm_schema_verified: bool = false,
    secondary_auth_verified: bool = false,
    pub fn validate(self: Evidence) !void {
        if (!self.verified or !self.web_headers_verified or self.profile_id.len == 0 or self.firmware.len == 0 or self.source_uri.len == 0 or self.public_key_pem.len == 0 or std.mem.allEqual(u8, &self.public_key_sha256, 0)) return error.AuthenticationEvidenceUnavailable;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.public_key_pem, &digest, .{});
        if (!std.crypto.timing_safe.eql([32]u8, digest, self.public_key_sha256)) return error.PublicKeyEvidenceMismatch;
    }
};
/// The provider must parse the PEM, require exactly RSA2048 and use a fresh
/// cryptographic random source for PKCS#1 v1.5. Auth verifies the 256-byte output.
pub const Encryptor = struct {
    context: *anyopaque,
    encrypt_rsa2048_pkcs1v15: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror![]u8,
};
var native_context: u8 = 0;
pub fn nativeEncryptor() Encryptor {
    return .{ .context = &native_context, .encrypt_rsa2048_pkcs1v15 = nativeEncrypt };
}
fn nativeEncrypt(_: *anyopaque, a: std.mem.Allocator, pem: []const u8, plaintext: []const u8) ![]u8 {
    return @import("tls.zig").encryptRsa2048(a, pem, plaintext);
}
pub fn evidenceFromProfile(selected: @import("profile.zig").Profile) !Evidence {
    try selected.validateForProduction();
    const source = selected.evidence;
    return .{ .profile_id = @tagName(selected.id), .firmware = source.firmware, .public_key_pem = source.public_key_pem, .public_key_sha256 = source.public_key_sha256, .source_uri = source.public_key_source, .verified = true, .web_headers_verified = source.web_login_schema_verified, .kvm_schema_verified = source.kvm_login_schema_verified };
}
pub const WebLogin = struct {
    body: Secret,
    pub const from = "WebUI";
    pub const requested_with = "XMLHttpRequest";
    pub fn deinit(self: *WebLogin) void {
        self.body.deinit();
        self.* = undefined;
    }
};
fn encrypt(a: std.mem.Allocator, evidence: Evidence, provider: Encryptor, password: []const u8) !Secret {
    try evidence.validate();
    if (password.len == 0 or password.len > 245) return error.InvalidPasswordLength;
    const ciphertext = try provider.encrypt_rsa2048_pkcs1v15(provider.context, a, evidence.public_key_pem, password);
    defer {
        std.crypto.secureZero(u8, ciphertext);
        a.free(ciphertext);
    }
    if (ciphertext.len != 256) return error.InvalidEncryptedPassword;
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(ciphertext.len));
    _ = std.base64.standard.Encoder.encode(encoded, ciphertext);
    return .{ .allocator = a, .bytes = encoded };
}
pub fn webLogin(a: std.mem.Allocator, evidence: Evidence, provider: Encryptor, username: []const u8, password: []const u8) !WebLogin {
    if (username.len == 0 or username.len > 256 or std.mem.indexOfAny(u8, username, "\r\n\x00") != null) return error.InvalidUsername;
    var encoded = try encrypt(a, evidence, provider, password);
    defer encoded.deinit();
    const body = try std.json.Stringify.valueAlloc(a, .{ .UserName = username, .Password = @as([]const u8, encoded.bytes) }, .{});
    return .{ .body = .{ .allocator = a, .bytes = body } };
}
pub const WebSession = struct {
    token: Secret,
    id: Secret,
    location: Secret,
    owner: identity.SessionHandle,
    pub fn deinit(self: *WebSession) void {
        self.token.deinit();
        self.id.deinit();
        self.location.deinit();
        self.* = undefined;
    }
};
pub const KvmSession = struct {
    token: Secret,
    id: ?Secret = null,
    verified_logout_uri: ?Secret = null,
    owner: identity.SessionHandle,
    pub fn deinit(self: *KvmSession) void {
        self.token.deinit();
        if (self.id) |*id| id.deinit();
        if (self.verified_logout_uri) |*uri| uri.deinit();
        self.* = undefined;
    }
};
pub fn acceptWebSession(a: std.mem.Allocator, origin: redfish.Origin, owner: identity.SessionHandle, doc: redfish.Document, token: []const u8, location: []const u8) !WebSession {
    if (!doc.accepted() or doc.status != 201 or token.len == 0 or token.len > 4096 or std.mem.indexOfAny(u8, token, "\r\n\x00") != null) return error.WebAuthenticationFailed;
    const id = redfish.text(doc.value, "Id") orelse return error.MissingWebSessionId;
    const path = try redfish.resourceUri(a, origin, location);
    defer a.free(path);
    if (id.len == 0 or id.len > 256 or std.mem.indexOfAny(u8, id, "/\\%?#\r\n\x00") != null or !std.mem.startsWith(u8, path, "/redfish/v1/SessionService/Sessions/") or !std.mem.endsWith(u8, path, id) or path[path.len - id.len - 1] != '/') return error.InvalidWebSessionLocation;
    var owned_token = try Secret.init(a, token);
    errdefer owned_token.deinit();
    var owned_id = try Secret.init(a, id);
    errdefer owned_id.deinit();
    return .{ .token = owned_token, .id = owned_id, .location = try Secret.init(a, path), .owner = owner };
}
pub fn kvmLogin(a: std.mem.Allocator, evidence: Evidence, session: WebSession, owner: identity.SessionHandle) !Secret {
    try evidence.validate();
    if (!evidence.kvm_schema_verified) return error.KvmAuthenticationEvidenceUnavailable;
    if (!owner.eql(session.owner)) return error.StaleSession;
    return .{ .allocator = a, .bytes = try std.json.Stringify.valueAlloc(a, .{ .Type = "WEB", .KvmAuthentication = @as([]const u8, session.id.bytes) }, .{}) };
}
/// Explicit body-token adapter for synthetic fixtures or another verified
/// schema. The observed Sugon response uses acceptKvmSessionHeader instead.
pub fn acceptKvmSession(a: std.mem.Allocator, evidence: Evidence, owner: identity.SessionHandle, doc: redfish.Document, token_field: []const u8, id_field: ?[]const u8) !KvmSession {
    try evidence.validate();
    if (!evidence.kvm_schema_verified or !doc.accepted()) return error.KvmAuthenticationFailed;
    const token = redfish.text(doc.value, token_field) orelse return error.MissingKvmToken;
    return ownKvmSession(a, owner, doc, token, id_field, false);
}
/// Production Sugon token source: the unique X-Auth-Token header on this OEM
/// KvmSessions response. The caller checks header multiplicity before passing
/// it here. Absence never falls back to a JSON field or a WEB session token.
/// Id is a separate owned body field; null id_field selects the observed "Id".
pub fn acceptKvmSessionHeader(a: std.mem.Allocator, evidence: Evidence, owner: identity.SessionHandle, doc: redfish.Document, header_token: ?[]const u8, id_field: ?[]const u8) !KvmSession {
    try evidence.validate();
    if (!evidence.kvm_schema_verified or !doc.accepted()) return error.KvmAuthenticationFailed;
    const token = header_token orelse return error.MissingKvmToken;
    return ownKvmSession(a, owner, doc, token, id_field orelse "Id", true);
}
fn ownKvmSession(a: std.mem.Allocator, owner: identity.SessionHandle, doc: redfish.Document, token: []const u8, id_field: ?[]const u8, require_id: bool) !KvmSession {
    if (token.len == 0 or token.len > 4096) return error.InvalidKvmToken;
    for (token) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", byte) != null)) return error.InvalidKvmToken;
    const id = if (id_field) |field| redfish.text(doc.value, field) else null;
    if (require_id) {
        const required = id orelse return error.MissingKvmSessionId;
        if (required.len == 0 or required.len > 256 or std.mem.eql(u8, required, ".") or std.mem.eql(u8, required, "..")) return error.InvalidKvmSessionId;
        for (required) |byte| if (byte <= 0x20 or byte >= 0x7f or std.mem.indexOfScalar(u8, "/\\%?#", byte) != null) return error.InvalidKvmSessionId;
    }
    var secret = try Secret.init(a, token);
    errdefer secret.deinit();
    return .{ .token = secret, .id = if (id) |value| try Secret.init(a, value) else null, .owner = owner };
}
pub const SecondaryProof = struct {
    owner: identity.SessionHandle,
    operation: svc.OperationKey,
    nonce: [16]u8,
    capability_revision: u64,
    grant_revision: u64,
    authkey: Secret,
    pub fn deinit(self: *SecondaryProof) void {
        self.authkey.deinit();
        self.* = undefined;
    }
};
pub fn secondaryProof(a: std.mem.Allocator, evidence: Evidence, provider: Encryptor, execution: svc.Execution, password: []const u8) !SecondaryProof {
    if (!evidence.secondary_auth_verified) return error.SecondaryAuthenticationEvidenceUnavailable;
    return .{ .owner = execution.call.owner, .operation = execution.operation, .nonce = execution.nonce, .capability_revision = execution.capability_revision, .grant_revision = execution.grant_revision, .authkey = try encrypt(a, evidence, provider, password) };
}
