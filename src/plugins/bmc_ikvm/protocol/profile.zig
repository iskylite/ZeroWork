//! Evidence-gated OEM profile with reviewed public material and sanitized
//! read-only protocol vectors for the exact Sugon 1.80 firmware family.
const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");

pub const Id = enum { sugon_1_80_oem_rfb };
pub const Identity = struct {
    /// All fields must come from the trusted management channel; no page title,
    /// IP heuristic, remote script evaluation or password attempts are used.
    trusted_channel: bool = false,
    manufacturer: []const u8,
    product: []const u8,
    processor_vendor: []const u8,
    bmc_chip: []const u8,
    firmware: []const u8,
    oem_namespace: []const u8,
    kvm_login_resource: []const u8,
    oem_rfb: bool,
};

/// Public device observations, before any credential is requested. The OEM
/// protocol routes belong to the reviewed profile evidence, rather than being
/// invented as observations when the public service root does not expose them.
pub const PublicIdentity = struct {
    trusted_channel: bool = false,
    copyright: []const u8,
    product: []const u8,
    processor_vendor: []const u8,
    bmc_chip: []const u8,
    firmware: []const u8,
    oem_namespace: []const u8,
    oem_redfish_version: ?[]const u8 = null,
};

/// Strings borrow the trusted root document. Manufacturer is deliberately not
/// used: this firmware reports N/A there. FirmwareVersion must be observed,
/// never substituted from the profile's own fixture or RedfishVersion.
pub fn publicIdentityFromRoot(trusted_channel: bool, root: std.json.Value) !PublicIdentity {
    if (!trusted_channel) return error.UntrustedProfileInput;
    const oem = jsonMember(root, "Oem") orelse return error.UnsupportedProfileIdentityUnavailable;
    const public = jsonMember(oem, "Public") orelse return error.UnsupportedProfileIdentityUnavailable;
    const root_firmware = jsonText(root, "FirmwareVersion");
    const public_firmware = jsonText(public, "FirmwareVersion");
    if (root_firmware != null and public_firmware != null and !std.mem.eql(u8, root_firmware.?, public_firmware.?)) return error.UnsupportedProfileIdentityConflict;
    return .{
        .trusted_channel = true,
        .copyright = if (jsonMember(public, "Copyright")) |copyright| (if (copyright == .string) copyright.string else jsonText(copyright, "EN") orelse return error.UnsupportedProfileIdentityUnavailable) else return error.UnsupportedProfileIdentityUnavailable,
        .product = jsonText(public, "ProductName") orelse return error.UnsupportedProfileIdentityUnavailable,
        .processor_vendor = jsonText(public, "Platform") orelse return error.UnsupportedProfileIdentityUnavailable,
        .bmc_chip = jsonText(public, "BMCChipModel") orelse return error.UnsupportedProfileIdentityUnavailable,
        .firmware = root_firmware orelse public_firmware orelse "",
        .oem_namespace = "Public",
        .oem_redfish_version = jsonText(public, "RedfishVersion"),
    };
}

fn jsonMember(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}
fn jsonText(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = jsonMember(value, key) orelse return null;
    return if (field == .string) field.string else null;
}

/// Matching the family without a version only permits a bounded anonymous
/// read of reviewed public material. It does not authorize authentication.
pub fn detectPublicFamily(identity: PublicIdentity) !Id {
    if (!identity.trusted_channel) return error.UntrustedProfileInput;
    if (!hasVendorWord(identity.copyright, "Sugon") or
        !std.mem.eql(u8, identity.product, "SuperPod") or
        !std.mem.eql(u8, identity.processor_vendor, "Hygon") or
        !std.mem.eql(u8, identity.bmc_chip, "AST2600-A3") or
        !std.mem.eql(u8, identity.oem_namespace, "Public")) return error.UnsupportedProfile;
    return .sugon_1_80_oem_rfb;
}

fn hasVendorWord(value: []const u8, word: []const u8) bool {
    if (value.len > 4096 or value.len < word.len) return false;
    for (0..value.len - word.len + 1) |index| {
        if (index != 0 and std.ascii.isAlphanumeric(value[index - 1])) continue;
        const end = index + word.len;
        if (end != value.len and std.ascii.isAlphanumeric(value[end])) continue;
        if (std.ascii.eqlIgnoreCase(value[index..end], word)) return true;
    }
    return false;
}

pub fn selectPublic(identity: PublicIdentity) !Profile {
    const id = try detectPublicFamily(identity);
    if (identity.firmware.len == 0) return error.UnsupportedProfileFirmwareUnavailable;
    if (!std.mem.eql(u8, identity.firmware, "1.80")) return error.UnsupportedProfile;
    return selectReviewed(id);
}

pub const PublicMaterial = struct { uri: []const u8, sha256: [32]u8 };

pub fn detectPublicEvidenceFamily(identity: PublicIdentity) !Id {
    const id = try detectPublicFamily(identity);
    if (identity.firmware.len != 0) return error.ProfileFirmwareAlreadyObserved;
    const version = identity.oem_redfish_version orelse return error.UnsupportedProfileFirmwareUnavailable;
    if (!std.mem.eql(u8, version, "1.17.2.0.3.8.0.21")) return error.UnsupportedProfile;
    return id;
}

/// Exact public asset evidence identifies the reviewed protocol family when
/// the anonymous root withholds firmware. This is evidence for one WEB schema,
/// not an observation of FirmwareVersion. The worker must confirm the actual
/// Manager firmware after WEB login and before creating an OEM/KVM session.
pub fn selectPublicEvidence(identity: PublicIdentity, material: PublicMaterial) !Profile {
    const id = try detectPublicEvidenceFamily(identity);
    if (!std.mem.eql(u8, material.uri, sugon_public_material_path) or
        !std.mem.eql(u8, &material.sha256, &sugon_public_material_sha256)) return error.UnsupportedProfilePublicEvidence;
    var selected = try selectReviewed(id);
    selected.identity_source = .reviewed_public_material;
    return selected;
}

pub const kvm_login_path = "/redfish/v1/SessionService/Sessions/Oem/Public/KvmSessions";
pub const video_path = "/kvm/0";
pub const client_preamble = "KVM ";

/// Strict classification from the recorded firmware-family observations. This
/// result alone never authorizes authentication or advertises compatibility.
pub fn detect(identity: Identity) !Id {
    if (!identity.trusted_channel) return error.UntrustedProfileInput;
    if (!std.mem.eql(u8, identity.manufacturer, "Sugon") or
        !std.mem.eql(u8, identity.product, "SuperPod") or
        !std.mem.eql(u8, identity.processor_vendor, "Hygon") or
        !std.mem.eql(u8, identity.bmc_chip, "AST2600-A3") or
        !std.mem.eql(u8, identity.firmware, "1.80") or
        !std.mem.eql(u8, identity.oem_namespace, "Public") or
        !std.mem.eql(u8, identity.kvm_login_resource, kvm_login_path) or !identity.oem_rfb)
        return error.UnsupportedProfile;
    return .sugon_1_80_oem_rfb;
}

pub const Logout = union(enum) {
    /// An evidence-backed response Location, validated against the BMC origin.
    own_session_location,
    /// Prefix and suffix are an observed OEM template, not a guessed route.
    own_id_template: struct { prefix: []const u8, suffix: []const u8 },
};
pub const Evidence = struct {
    firmware: []const u8,
    /// Digest of the complete sanitized identity/schema fixture for this exact
    /// firmware. Production validation binds it to the embedded public fixture.
    identity_fixture_sha256: [32]u8,
    public_key_pem: []const u8,
    public_key_sha256: [32]u8,
    public_key_source: []const u8,
    web_login_schema_verified: bool,
    kvm_login_schema_verified: bool,
    ws_subprotocol_echo_verified: bool,
    oem_handshake_verified: bool,
    web_logout: ?Logout,
    kvm_logout: ?Logout,
};

pub const Profile = struct {
    id: Id,
    evidence: Evidence,
    synthetic: bool,
    identity_source: enum { observed_firmware, reviewed_public_material } = .observed_firmware,
    pub fn validateForProduction(self: Profile) !void {
        if (self.synthetic) return error.SyntheticProfileForbidden;
        try validateEvidence(self.evidence);
        try validateFixedMaterials();
        if (!std.mem.eql(u8, &self.evidence.identity_fixture_sha256, &sugon_fixture_sha256) or
            !std.mem.eql(u8, &self.evidence.public_key_sha256, &sugon_public_key_sha256) or
            !std.mem.eql(u8, self.evidence.public_key_source, sugon_public_key_source)) return error.ProfileEvidenceMismatch;
        switch (self.evidence.web_logout.?) {
            .own_session_location => {},
            else => return error.ProfileEvidenceMismatch,
        }
        switch (self.evidence.kvm_logout.?) {
            .own_id_template => |rule| if (!std.mem.eql(u8, rule.prefix, kvm_login_path ++ "/") or rule.suffix.len != 0) return error.ProfileEvidenceMismatch,
            else => return error.ProfileEvidenceMismatch,
        }
    }
};

/// Public key only: no private key, login ciphertext, token or host identity.
pub const sugon_public_key_pem = @embedFile("profile_fixtures/sugon_1_80_rsa2048.pem");
pub const sugon_public_fixture = @embedFile("profile_fixtures/sugon_1_80.json");
pub const sugon_public_key_sha256 = digestBytes("3f3bd3f8a4837161f4dff9c6cce1110d38b2eb1d873d39c6c1d33173eccd71d6");
pub const sugon_fixture_sha256 = digestBytes("4408bc8d352fd22303cb92c81a4ac98e94a8fa1fa02ecaedc291755cd68c09f2");
pub const sugon_public_key_source = "/js/app.0bc71eb0.js#rsa2048-public-key";
pub const sugon_public_material_path = "/js/app.0bc71eb0.js";
pub const sugon_public_material_sha256 = digestBytes("4470c19b553d1e64cf529c1709843ce334b110501d090b4dc02c2a2e74ca95c7");

fn digestBytes(comptime hex: []const u8) [32]u8 {
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch @compileError("invalid fixed profile digest");
    return bytes;
}
fn validateFixedMaterials() !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(sugon_public_key_pem, &digest, .{});
    if (!std.mem.eql(u8, &digest, &sugon_public_key_sha256)) return error.ProfileEvidenceMismatch;
    std.crypto.hash.sha2.Sha256.hash(sugon_public_fixture, &digest, .{});
    if (!std.mem.eql(u8, &digest, &sugon_fixture_sha256)) return error.ProfileEvidenceMismatch;
}

/// Only this exact trusted identity and the reviewed embedded evidence can
/// enable the observed authentication/video protocol. This does not prove or
/// grant power/boot writes, input effects or compatibility with other firmware.
pub fn select(identity: Identity) !Profile {
    const id = try detect(identity);
    return selectReviewed(id);
}

fn selectReviewed(id: Id) !Profile {
    const selected: Profile = .{ .id = id, .synthetic = false, .evidence = .{
        .firmware = "1.80",
        .identity_fixture_sha256 = sugon_fixture_sha256,
        .public_key_pem = sugon_public_key_pem,
        .public_key_sha256 = sugon_public_key_sha256,
        .public_key_source = sugon_public_key_source,
        .web_login_schema_verified = true,
        .kvm_login_schema_verified = true,
        .ws_subprotocol_echo_verified = true,
        .oem_handshake_verified = true,
        .web_logout = .own_session_location,
        .kvm_logout = .{ .own_id_template = .{ .prefix = kvm_login_path ++ "/", .suffix = "" } },
    } };
    try selected.validateForProduction();
    return selected;
}

/// Synthetic evidence exercises parsers/auth in Zig test builds only. It cannot
/// become a production profile even when its fields resemble historical data.
pub fn syntheticForTest(identity: Identity, evidence: Evidence) !Profile {
    if (!builtin.is_test) return error.SyntheticProfileForbidden;
    const id = try detect(identity);
    try validateEvidence(evidence);
    return .{ .id = id, .evidence = evidence, .synthetic = true };
}

fn validateEvidence(evidence: Evidence) !void {
    if (!std.mem.eql(u8, evidence.firmware, "1.80") or
        evidence.public_key_pem.len == 0 or evidence.public_key_source.len == 0 or
        !evidence.web_login_schema_verified or !evidence.kvm_login_schema_verified or
        !evidence.ws_subprotocol_echo_verified or !evidence.oem_handshake_verified or
        evidence.web_logout == null or evidence.kvm_logout == null or
        allZero(evidence.identity_fixture_sha256)) return error.ProfileEvidenceMissing;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(evidence.public_key_pem, &digest, .{});
    if (!std.mem.eql(u8, &digest, &evidence.public_key_sha256)) return error.ProfileEvidenceMismatch;
}
fn allZero(bytes: [32]u8) bool {
    for (bytes) |b| if (b != 0) return false;
    return true;
}

/// Logout is always for this client's own recorded session. Template ids are
/// opaque single segments; tokens or an arbitrary resource cannot be used.
pub fn logoutReference(allocator: std.mem.Allocator, origin: http.Origin, rule: Logout, own_location: ?[]const u8, own_id: []const u8) ![]u8 {
    return switch (rule) {
        .own_session_location => allocator.dupe(u8, try origin.validateReference(own_location orelse return error.SessionLocationMissing)),
        .own_id_template => |template| blk: {
            if (own_id.len == 0 or own_id.len > 256) return error.InvalidSessionId;
            for (own_id) |ch| switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.' => {},
                else => return error.InvalidSessionId,
            };
            if (std.mem.eql(u8, own_id, ".") or std.mem.eql(u8, own_id, "..")) return error.InvalidSessionId;
            const uri = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ template.prefix, own_id, template.suffix });
            errdefer allocator.free(uri);
            const path = try origin.validateReference(uri);
            // Template rules are origin-form so no hidden authority survives.
            if (path.ptr != uri.ptr) return error.InvalidLogoutTemplate;
            break :blk uri;
        },
    };
}
