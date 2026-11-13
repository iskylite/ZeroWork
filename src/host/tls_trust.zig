//! Target TLS trust is independent from SSH host-key trust. A facade only serves
//! its complete SessionHandle, and every exception is scoped to the original
//! authority, operation/attempt, ordered DER chain and exact failure set.
const std = @import("std");
const identity = @import("identity.zig");
pub const OperationKey = @import("operation.zig").OperationKey;

pub const Authority = struct { host: []const u8, port: u16 = 443 };
pub const Fingerprint = [32]u8;
pub const max_chain_certificates = 16;
pub const max_chain_bytes = 1024 * 1024;

/// A value, rather than borrowed endpoint text, can safely cross a challenge.
pub const CanonicalAuthority = struct {
    storage: [255]u8 = @splat(0),
    length: u16 = 0,
    port: u16,

    pub fn host(self: *const CanonicalAuthority) []const u8 {
        return self.storage[0..self.length];
    }
    pub fn eql(self: *const CanonicalAuthority, other: *const CanonicalAuthority) bool {
        return self.port == other.port and std.mem.eql(u8, self.host(), other.host());
    }
    pub fn digest(self: *const CanonicalAuthority) Fingerprint {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(self.host());
        var port_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &port_bytes, self.port, .big);
        hash.update(&port_bytes);
        return hash.finalResult();
    }
};

/// IPv6 is canonicalized by inet_pton/inet_ntop, IPv4 by strict decimal octets.
/// DNS inputs must already be ASCII A-labels; no DNS lookup is performed.
pub fn canonicalize(authority: Authority) !CanonicalAuthority {
    if (authority.port == 0 or authority.host.len == 0 or authority.host.len > 255) return error.InvalidAuthority;
    var result: CanonicalAuthority = .{ .port = authority.port };
    var host = authority.host;
    for (host) |byte| if (byte <= 0x20 or byte >= 0x7f) return error.InvalidAuthority;
    const bracketed = host[0] == '[';
    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return error.InvalidAuthority;
        host = host[1 .. host.len - 1];
    }
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        for (host) |byte| if (!std.ascii.isHex(byte) and byte != ':' and byte != '.') return error.InvalidAuthority;
        var input: [256:0]u8 = @splat(0);
        @memcpy(input[0..host.len], host);
        var binary: [16]u8 = undefined;
        if (inet_pton(30, &input, &binary) != 1) return error.InvalidAuthority;
        var output: [46:0]u8 = @splat(0);
        if (inet_ntop(30, &binary, &output, output.len) == null) return error.InvalidAuthority;
        const len = std.mem.indexOfScalar(u8, &output, 0).?;
        @memcpy(result.storage[0..len], output[0..len]);
        result.length = @intCast(len);
        return result;
    }
    if (bracketed) return error.InvalidAuthority;
    if (host[host.len - 1] == '.') host = host[0 .. host.len - 1];
    if (host.len == 0 or host.len > 253) return error.InvalidAuthority;
    var numeric = true;
    for (host) |byte| if (!std.ascii.isDigit(byte) and byte != '.') {
        numeric = false;
        break;
    };
    if (numeric) {
        var parts = std.mem.splitScalar(u8, host, '.');
        var count: usize = 0;
        while (parts.next()) |part| {
            if (part.len == 0 or part.len > 3 or (part.len > 1 and part[0] == '0')) return error.InvalidAuthority;
            _ = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAuthority;
            count += 1;
        }
        if (count != 4) return error.InvalidAuthority;
    } else {
        var labels = std.mem.splitScalar(u8, host, '.');
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return error.InvalidAuthority;
            for (label) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidAuthority;
        }
    }
    for (host, 0..) |byte, index| result.storage[index] = std.ascii.toLower(byte);
    result.length = @intCast(host.len);
    return result;
}
extern "c" fn inet_pton(c_int, [*:0]const u8, *anyopaque) c_int;
extern "c" fn inet_ntop(c_int, *const anyopaque, [*]u8, u32) ?[*:0]const u8;

pub const FailureSet = packed struct(u32) {
    untrusted_issuer: bool = false,
    expired: bool = false,
    not_yet_valid: bool = false,
    hostname_mismatch: bool = false,
    revoked: bool = false,
    invalid_chain: bool = false,
    evaluation_unavailable: bool = false,
    /// The certificate's total validity span violates the platform maximum.
    /// This is separate from whether the current date is outside its interval.
    excessive_validity: bool = false,
    reserved: u24 = 0,

    pub fn bits(self: FailureSet) u32 {
        return @bitCast(self);
    }
    pub fn empty(self: FailureSet) bool {
        return self.bits() == 0;
    }
    pub fn canExcept(self: FailureSet) bool {
        return !self.empty() and (self.bits() & ~@as(u32, 0x8f)) == 0;
    }
};

pub fn describeFailures(a: std.mem.Allocator, failures: FailureSet) ![]u8 {
    var material: std.Io.Writer.Allocating = .init(a);
    defer material.deinit();
    if (failures.untrusted_issuer) try material.writer.writeAll("- 证书颁发者不受信任（可能为自签名证书或未知 CA）\n");
    if (failures.expired) try material.writer.writeAll("- 证书已过期\n");
    if (failures.not_yet_valid) try material.writer.writeAll("- 证书尚未生效\n");
    if (failures.hostname_mismatch) try material.writer.writeAll("- 证书主机名与目标不匹配\n");
    if (failures.excessive_validity) try material.writer.writeAll("- 证书总有效期超过系统允许上限\n");
    if (failures.revoked) try material.writer.writeAll("- 证书已被吊销（不允许例外）\n");
    if (failures.invalid_chain) try material.writer.writeAll("- 证书链无效（不允许例外）\n");
    if (failures.evaluation_unavailable) try material.writer.writeAll("- 系统证书验证不可用（不允许例外）\n");
    if (failures.reserved != 0) try material.writer.writeAll("- 未知证书验证失败（不允许例外）\n");
    if (failures.empty()) try material.writer.writeAll("- 无\n");
    if (material.written().len != 0 and material.written()[material.written().len - 1] == '\n') material.writer.end -= 1;
    return material.toOwnedSlice();
}

pub fn utcDate(a: std.mem.Allocator, seconds: i64) ![]u8 {
    // Keep malformed/out-of-range certificate metadata honest. A 400-year
    // Gregorian cycle lets the unsigned epoch API also format pre-1970 dates.
    if (seconds < -62135596800 or seconds > 253402300799) return std.fmt.allocPrint(a, "超出可显示的 UTC 日期范围（Unix 秒：{d}）", .{seconds});
    const cycle_seconds = 146097 * @as(i64, std.time.epoch.secs_per_day);
    const cycles = if (seconds < 0) @divFloor(seconds, cycle_seconds) else 0;
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds - cycles * cycle_seconds) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    const year: u16 = @intCast(@as(i64, year_day.year) + cycles * 400);
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ year, @backingInt(month_day.month), month_day.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

pub const VerificationResult = struct {
    failures: FailureSet = .{},
    leaf_fingerprint: Fingerprint = @splat(0),
    chain_fingerprint: Fingerprint = @splat(0),
    subject: [256]u8 = @splat(0),
    subject_length: u16 = 0,
    issuer: [256]u8 = @splat(0),
    issuer_length: u16 = 0,
    not_before_unix: i64 = 0,
    not_after_unix: i64 = 0,
    native_status: i32 = 0,

    pub fn subjectText(self: *const VerificationResult) []const u8 {
        return self.subject[0..self.subject_length];
    }
    pub fn issuerText(self: *const VerificationResult) []const u8 {
        return self.issuer[0..self.issuer_length];
    }
};

pub const Verifier = struct {
    context: ?*anyopaque = null,
    verify: *const fn (?*anyopaque, Authority, []const []const u8) anyerror!VerificationResult,

    pub fn native() Verifier {
        return .{ .verify = verifyNative };
    }
};

pub const Pin = struct {
    leaf_fingerprint: Fingerprint,
    chain_fingerprint: Fingerprint,
    exceptions: FailureSet,

    pub fn eql(self: Pin, other: Pin) bool {
        return std.mem.eql(u8, &self.leaf_fingerprint, &other.leaf_fingerprint) and
            std.mem.eql(u8, &self.chain_fingerprint, &other.chain_fingerprint) and self.exceptions.bits() == other.exceptions.bits();
    }
    fn from(result: VerificationResult) Pin {
        return .{ .leaf_fingerprint = result.leaf_fingerprint, .chain_fingerprint = result.chain_fingerprint, .exceptions = result.failures };
    }
};

/// save is a durable compare-and-swap. It must not publish memory-only success.
/// The expected pin prevents two processes overwriting a changed trust record.
pub const PinBackend = struct {
    context: *anyopaque,
    load: *const fn (*anyopaque, Fingerprint) anyerror!?Pin,
    save: *const fn (*anyopaque, Fingerprint, ?Pin, Pin) anyerror!void,
};

pub const Challenge = struct {
    id: u64,
    owner: identity.SessionHandle,
    operation: OperationKey,
    authority: CanonicalAuthority,
    verification: VerificationResult,
    scope_changed: bool = false,
};
pub const TrustChoice = enum { once, persistent, reject };
pub const TrustSource = enum { system, once, persistent_pin };
pub const Denial = enum { rejected, certificate_changed, unexceptable_failure };
pub const Evaluation = union(enum) {
    trusted: struct { source: TrustSource, verification: VerificationResult },
    challenge: Challenge,
    denied: struct { reason: Denial, verification: VerificationResult },
};

const PinScope = enum {
    bmc,
    web,

    fn digest(self: PinScope, authority: CanonicalAuthority) Fingerprint {
        const key = authority.digest();
        if (self == .bmc) return key;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("zerowork/web-tls/v1\x00");
        hash.update(&key);
        return hash.finalResult();
    }
};
const Pending = struct { challenge: Challenge, prior_pin: ?Pin, scope: PinScope };
const Once = struct { owner: identity.SessionHandle, operation: OperationKey, authority: CanonicalAuthority, pin: Pin, scope: PinScope };

/// Stored only by the host. The public facade's owner is a consistency check;
/// it never selects the authority used by the backend.
const FacadeContext = struct {
    store: *Store,
    owner: identity.SessionHandle,

    fn resolve(raw: ?*anyopaque, owner: identity.SessionHandle) !*FacadeContext {
        const self: *FacadeContext = @ptrCast(@alignCast(raw orelse return error.SecurityIdentityCapacity));
        if (!self.owner.eql(owner)) return error.WrongOwner;
        return self;
    }
    fn evaluate(raw: ?*anyopaque, owner: identity.SessionHandle, operation: OperationKey, authority: Authority, chain: []const []const u8, scope: PinScope) !Evaluation {
        const self = try resolve(raw, owner);
        return self.store.evaluate(self.owner, operation, authority, chain, scope);
    }
    fn answer(raw: ?*anyopaque, owner: identity.SessionHandle, challenge: Challenge, choice: TrustChoice) !Evaluation {
        const self = try resolve(raw, owner);
        return self.store.answer(self.owner, challenge, choice);
    }
};

/// Keep this store at a stable address until every facade is retired. deinit is
/// called after workers stop. The native verifier never changes system roots.
pub const Store = struct {
    allocator: std.mem.Allocator,
    verifier: Verifier,
    pins: ?PinBackend,
    mutex: std.atomic.Mutex = .unlocked,
    pending: std.ArrayList(Pending) = .empty,
    once: std.ArrayList(Once) = .empty,
    facade_contexts: std.ArrayList(*FacadeContext) = .empty,
    revoked_owners: std.ArrayList(identity.SessionHandle) = .empty,
    revoked_operations: std.ArrayList(OperationKey) = .empty,
    revocation_exhausted: bool = false,
    next_challenge: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, verifier: Verifier, pins: ?PinBackend) Store {
        return .{ .allocator = allocator, .verifier = verifier, .pins = pins };
    }
    pub fn deinit(self: *Store) void {
        self.pending.deinit(self.allocator);
        self.once.deinit(self.allocator);
        for (self.facade_contexts.items) |context| self.allocator.destroy(context);
        self.facade_contexts.deinit(self.allocator);
        self.revoked_owners.deinit(self.allocator);
        self.revoked_operations.deinit(self.allocator);
    }
    pub fn facade(self: *Store, owner: identity.SessionHandle) Facade {
        self.lock();
        defer self.mutex.unlock();
        for (self.facade_contexts.items) |context| if (context.owner.eql(owner)) return .{ .context = context, .owner = owner };
        if (@backingInt(owner.session_id) == 0 or owner.generation == 0 or self.facade_contexts.items.len >= 4096) return .{ .context = null, .owner = owner };
        const context = self.allocator.create(FacadeContext) catch return .{ .context = null, .owner = owner };
        context.* = .{ .store = self, .owner = owner };
        self.facade_contexts.append(self.allocator, context) catch {
            self.allocator.destroy(context);
            return .{ .context = null, .owner = owner };
        };
        return .{ .context = context, .owner = owner };
    }
    fn lock(self: *Store) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
    pub fn cancelOperation(self: *Store, operation: OperationKey) void {
        self.lock();
        defer self.mutex.unlock();
        var known = false;
        for (self.revoked_operations.items) |key| if (key.eql(operation)) {
            known = true;
            break;
        };
        if (!known) {
            if (self.revoked_operations.items.len >= 4096) self.revocation_exhausted = true else self.revoked_operations.append(self.allocator, operation) catch {
                self.revocation_exhausted = true;
            };
        }
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].challenge.operation.eql(operation)) _ = self.pending.swapRemove(i) else i += 1;
        }
        i = 0;
        while (i < self.once.items.len) {
            if (self.once.items[i].operation.eql(operation)) _ = self.once.swapRemove(i) else i += 1;
        }
    }
    pub fn cancelOwner(self: *Store, owner: identity.SessionHandle) void {
        self.lock();
        defer self.mutex.unlock();
        var known = false;
        for (self.revoked_owners.items) |key| if (key.eql(owner)) {
            known = true;
            break;
        };
        if (!known) {
            if (self.revoked_owners.items.len >= 4096) self.revocation_exhausted = true else self.revoked_owners.append(self.allocator, owner) catch {
                self.revocation_exhausted = true;
            };
        }
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].challenge.owner.eql(owner)) _ = self.pending.swapRemove(i) else i += 1;
        }
        i = 0;
        while (i < self.once.items.len) {
            if (self.once.items[i].owner.eql(owner)) _ = self.once.swapRemove(i) else i += 1;
        }
    }
    fn evaluate(self: *Store, owner: identity.SessionHandle, operation: OperationKey, authority: Authority, chain: []const []const u8, scope: PinScope) !Evaluation {
        try requireOperation(owner, operation);
        self.lock();
        self.requireLive(owner, operation) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        const canonical = try canonicalize(authority);
        try validateChain(chain);
        var verification = try self.verifier.verify(self.verifier.context, .{ .host = canonical.host(), .port = canonical.port }, chain);
        if (verification.subject_length > verification.subject.len or verification.issuer_length > verification.issuer.len) return error.InvalidVerification;
        // The store computes fingerprints itself; an injected evaluator cannot
        // widen an exception by supplying unrelated certificate identifiers.
        verification.leaf_fingerprint = fingerprint(chain[0]);
        verification.chain_fingerprint = chainFingerprint(chain);
        const candidate = Pin.from(verification);
        self.lock();
        defer self.mutex.unlock();
        try self.requireLive(owner, operation);
        const old_pin = if (self.pins) |backend| try backend.load(backend.context, scope.digest(canonical)) else null;
        if (scope == .bmc and old_pin != null and !std.mem.eql(u8, &old_pin.?.leaf_fingerprint, &candidate.leaf_fingerprint)) {
            self.invalidatePending(operation, canonical, scope);
            return .{ .denied = .{ .reason = .certificate_changed, .verification = verification } };
        }
        if (!verification.failures.empty() and !verification.failures.canExcept()) {
            self.invalidatePending(operation, canonical, scope);
            return .{ .denied = .{ .reason = .unexceptable_failure, .verification = verification } };
        }
        if (old_pin) |pin| {
            if (pin.eql(candidate)) {
                self.invalidatePending(operation, canonical, scope);
                return .{ .trusted = .{ .source = .persistent_pin, .verification = verification } };
            }
        }
        for (self.once.items) |grant| {
            if (grant.scope == scope and grant.owner.eql(owner) and grant.operation.eql(operation) and grant.authority.eql(&canonical) and grant.pin.eql(candidate)) {
                self.invalidatePending(operation, canonical, scope);
                return .{ .trusted = .{ .source = .once, .verification = verification } };
            }
        }
        if (old_pin == null and verification.failures.empty()) {
            self.invalidatePending(operation, canonical, scope);
            return .{ .trusted = .{ .source = .system, .verification = verification } };
        }
        for (self.pending.items) |entry| {
            if (entry.scope == scope and entry.challenge.operation.eql(operation) and entry.challenge.authority.eql(&canonical) and Pin.from(entry.challenge.verification).eql(candidate))
                return .{ .challenge = entry.challenge };
        }
        // A new peer/exception invalidates the older prompt for this endpoint.
        self.invalidatePending(operation, canonical, scope);
        if (self.pending.items.len >= 64) return error.TrustChallengeQueueFull;
        if (self.next_challenge == std.math.maxInt(u64)) return error.TrustChallengeExhausted;
        const challenge: Challenge = .{ .id = self.next_challenge, .owner = owner, .operation = operation, .authority = canonical, .verification = verification, .scope_changed = old_pin != null };
        try self.pending.append(self.allocator, .{ .challenge = challenge, .prior_pin = old_pin, .scope = scope });
        self.next_challenge += 1;
        return .{ .challenge = challenge };
    }
    fn invalidatePending(self: *Store, operation: OperationKey, authority: CanonicalAuthority, scope: PinScope) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].scope == scope and self.pending.items[i].challenge.operation.eql(operation) and self.pending.items[i].challenge.authority.eql(&authority)) _ = self.pending.swapRemove(i) else i += 1;
        }
    }
    fn answer(self: *Store, owner: identity.SessionHandle, challenge: Challenge, choice: TrustChoice) !Evaluation {
        try requireOperation(owner, challenge.operation);
        if (!owner.eql(challenge.owner)) return error.WrongOwner;
        self.lock();
        defer self.mutex.unlock();
        try self.requireLive(owner, challenge.operation);
        for (self.pending.items, 0..) |entry, index| {
            if (entry.challenge.id != challenge.id) continue;
            const saved = entry.challenge;
            if (!saved.owner.eql(owner) or !saved.operation.eql(challenge.operation) or !saved.authority.eql(&challenge.authority) or
                !Pin.from(saved.verification).eql(Pin.from(challenge.verification)) or saved.scope_changed != challenge.scope_changed) return error.TrustChallengeMismatch;
            if (choice == .reject) {
                _ = self.pending.swapRemove(index);
                return .{ .denied = .{ .reason = .rejected, .verification = saved.verification } };
            }
            const candidate = Pin.from(saved.verification);
            const current = if (self.pins) |backend| try backend.load(backend.context, entry.scope.digest(saved.authority)) else null;
            if (!optionalPinEqual(current, entry.prior_pin)) return error.TrustPinConflict;
            if (choice == .persistent) {
                const backend = self.pins orelse return error.PersistentTrustUnavailable;
                try backend.save(backend.context, entry.scope.digest(saved.authority), entry.prior_pin, candidate);
            } else {
                if (self.once.items.len >= 256) return error.TrustLeaseLimit;
                try self.once.append(self.allocator, .{ .owner = owner, .operation = saved.operation, .authority = saved.authority, .pin = candidate, .scope = entry.scope });
            }
            _ = self.pending.swapRemove(index);
            return .{ .trusted = .{ .source = if (choice == .persistent) .persistent_pin else .once, .verification = saved.verification } };
        }
        return error.TrustChallengeMismatch;
    }
    fn requireLive(self: *const Store, owner: identity.SessionHandle, operation: OperationKey) !void {
        if (self.revocation_exhausted) return error.SecurityRevocationCapacity;
        for (self.revoked_owners.items) |key| if (key.eql(owner)) return error.OwnerRevoked;
        for (self.revoked_operations.items) |key| if (key.eql(operation)) return error.OperationRevoked;
    }
};

pub const Facade = struct {
    context: ?*anyopaque,
    owner: identity.SessionHandle,

    pub fn evaluate(self: Facade, operation: OperationKey, authority: Authority, chain: []const []const u8) !Evaluation {
        return FacadeContext.evaluate(self.context, self.owner, operation, authority, chain, .bmc);
    }

    pub fn evaluateWeb(self: Facade, operation: OperationKey, authority: Authority, chain: []const []const u8) !Evaluation {
        return FacadeContext.evaluate(self.context, self.owner, operation, authority, chain, .web);
    }
    pub fn answer(self: Facade, challenge: Challenge, choice: TrustChoice) !Evaluation {
        return FacadeContext.answer(self.context, self.owner, challenge, choice);
    }
};

pub fn requireOperation(owner: identity.SessionHandle, operation: OperationKey) !void {
    if (@backingInt(owner.session_id) == 0 or owner.generation == 0 or operation.operation_id == 0 or operation.attempt_id == 0) return error.InvalidOperation;
    if (operation.owner != .session or !operation.owner.session.eql(owner)) return error.WrongOwner;
}
pub fn fingerprint(bytes: []const u8) Fingerprint {
    var value: Fingerprint = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &value, .{});
    return value;
}
pub fn chainFingerprint(chain: []const []const u8) Fingerprint {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (chain) |der| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(der.len), .big);
        hash.update(&length);
        hash.update(der);
    }
    return hash.finalResult();
}
fn validateChain(chain: []const []const u8) !void {
    if (chain.len == 0 or chain.len > max_chain_certificates) return error.InvalidCertificateChain;
    var total: usize = 0;
    for (chain) |der| {
        if (der.len == 0 or der.len > max_chain_bytes - total) return error.CertificateChainTooLarge;
        total += der.len;
    }
}
fn optionalPinEqual(a: ?Pin, b: ?Pin) bool {
    if (a) |pin| return if (b) |other| pin.eql(other) else false;
    return b == null;
}

const NativeDer = extern struct { data: [*]const u8, length: usize };
const NativeVerification = extern struct {
    failures: u32,
    native_status: i32,
    not_before_unix: i64,
    not_after_unix: i64,
    subject: [256]u8,
    issuer: [256]u8,
};
extern "c" fn zw_bmc_tls_evaluate([*:0]const u8, [*]const NativeDer, usize, *NativeVerification) c_int;
extern "c" fn zw_bmc_tls_pin_load([*:0]const u8, *const Fingerprint, *[68]u8) c_int;
extern "c" fn zw_bmc_tls_pin_save([*:0]const u8, *const Fingerprint, ?*const [68]u8, *const [68]u8) c_int;
fn verifyNative(_: ?*anyopaque, authority: Authority, chain: []const []const u8) !VerificationResult {
    const canonical = try canonicalize(authority);
    try validateChain(chain);
    var host: [256:0]u8 = @splat(0);
    @memcpy(host[0..canonical.length], canonical.host());
    var values: [max_chain_certificates]NativeDer = undefined;
    for (chain, 0..) |der, index| values[index] = .{ .data = der.ptr, .length = der.len };
    var result: NativeVerification = undefined;
    if (zw_bmc_tls_evaluate(&host, &values, chain.len, &result) != 0) return error.TrustEvaluationUnavailable;
    return .{
        .failures = @bitCast(result.failures),
        .native_status = result.native_status,
        .subject = result.subject,
        .subject_length = @intCast(std.mem.indexOfScalar(u8, &result.subject, 0) orelse result.subject.len),
        .issuer = result.issuer,
        .issuer_length = @intCast(std.mem.indexOfScalar(u8, &result.issuer, 0) orelse result.issuer.len),
        .not_before_unix = result.not_before_unix,
        .not_after_unix = result.not_after_unix,
    };
}

/// A dedicated application-owned directory is required. The native backend
/// refuses symlinks and writable-by-other directories/files, locks across
/// processes, checks the expected record, then fsyncs temp+rename+directory.
pub const FilePinStore = struct {
    allocator: std.mem.Allocator,
    directory: [:0]u8,

    pub fn init(allocator: std.mem.Allocator, directory: []const u8) !FilePinStore {
        if (directory.len < 2 or directory[0] != '/' or std.mem.indexOfScalar(u8, directory, 0) != null) return error.InvalidTrustDirectory;
        var segments = std.mem.splitScalar(u8, directory[1..], '/');
        while (segments.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidTrustDirectory;
        return .{ .allocator = allocator, .directory = try allocator.dupeSentinel(u8, directory, 0) };
    }
    pub fn deinit(self: *FilePinStore) void {
        self.allocator.free(self.directory);
    }
    pub fn backend(self: *FilePinStore) PinBackend {
        return .{ .context = self, .load = load, .save = save };
    }
    fn load(context: *anyopaque, key: Fingerprint) !?Pin {
        const self: *FilePinStore = @ptrCast(@alignCast(context));
        var bytes: [68]u8 = undefined;
        const status = zw_bmc_tls_pin_load(self.directory, &key, &bytes);
        if (status == 1) return null;
        if (status != 0) return error.TrustStorageFailure;
        const exceptions: FailureSet = @bitCast(std.mem.readInt(u32, bytes[64..68], .big));
        if (!exceptions.empty() and !exceptions.canExcept()) return error.InvalidTrustPin;
        return .{ .leaf_fingerprint = bytes[0..32].*, .chain_fingerprint = bytes[32..64].*, .exceptions = exceptions };
    }
    fn encode(pin: Pin) [68]u8 {
        var bytes: [68]u8 = undefined;
        @memcpy(bytes[0..32], &pin.leaf_fingerprint);
        @memcpy(bytes[32..64], &pin.chain_fingerprint);
        std.mem.writeInt(u32, bytes[64..68], pin.exceptions.bits(), .big);
        return bytes;
    }
    fn save(context: *anyopaque, key: Fingerprint, expected: ?Pin, next: Pin) !void {
        const self: *FilePinStore = @ptrCast(@alignCast(context));
        const prior_bytes: ?[68]u8 = if (expected) |pin| encode(pin) else null;
        const next_bytes = encode(next);
        const status = zw_bmc_tls_pin_save(self.directory, &key, if (prior_bytes) |*bytes| bytes else null, &next_bytes);
        if (status == 2) return error.TrustPinConflict;
        if (status != 0) return error.TrustStorageFailure;
    }
};
