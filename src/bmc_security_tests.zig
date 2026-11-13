const std = @import("std");
const tls = @import("host/tls_trust.zig");
const secrets = @import("host/secret_lease.zig");
const actions = @import("host/resource_actions.zig");
const identity = @import("host/identity.zig");
const credentials = @import("config/credential_store.zig");
const a = std.testing.allocator;
const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(101), .generation = 7 };
const second_owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(102), .generation = 1 };
fn operation(handle: identity.SessionHandle, id: u64, attempt: u64) tls.OperationKey {
    return .{ .owner = .{ .session = handle }, .operation_id = id, .attempt_id = attempt };
}
const op = operation(owner, 11, 2);
const authority: tls.Authority = .{ .host = "BMC-Fixture.Example.", .port = 8443 };
const chain: []const []const u8 = &.{ "synthetic-leaf", "synthetic-intermediate" };
const FakeVerifier = struct {
    failures: tls.FailureSet = .{ .untrusted_issuer = true },
    calls: usize = 0,
    fn verifier(self: *FakeVerifier) tls.Verifier {
        return .{ .context = self, .verify = verify };
    }
    fn verify(context: ?*anyopaque, _: tls.Authority, _: []const []const u8) !tls.VerificationResult {
        const self: *FakeVerifier = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        return .{ .failures = self.failures };
    }
};

test "BMC authorities canonicalize without DNS and reject URL/parser ambiguities" {
    const first = try tls.canonicalize(authority);
    const second = try tls.canonicalize(.{ .host = "bmc-fixture.example", .port = 8443 });
    try std.testing.expect(first.eql(&second));
    try std.testing.expectEqualStrings("bmc-fixture.example", first.host());
    const ipv6 = try tls.canonicalize(.{ .host = "[2001:0db8:0:0:0:0:0:1]" });
    try std.testing.expectEqualStrings("2001:db8::1", ipv6.host());
    for ([_][]const u8{ "https://example.com", "user@example.com", "localhost:443", "127.00.0.1", "127.1", "a..example", "example.com/", "a%2eexample", "::1%lo0" }) |text|
        try std.testing.expectError(error.InvalidAuthority, tls.canonicalize(.{ .host = text }));
}

test "BMC TLS trust binds owner operation attempt original authority chain and failure set" {
    var verifier: FakeVerifier = .{};
    var store = tls.Store.init(a, verifier.verifier(), null);
    defer store.deinit();
    const facade = store.facade(owner);
    try std.testing.expectError(error.WrongOwner, facade.evaluate(operation(second_owner, 11, 2), authority, chain));
    try std.testing.expectEqual(@as(usize, 0), verifier.calls);
    const prompt = (try facade.evaluate(op, authority, chain)).challenge;
    try std.testing.expectEqualStrings("bmc-fixture.example", prompt.authority.host());
    var wrong = prompt;
    wrong.operation.attempt_id = 3;
    try std.testing.expectError(error.TrustChallengeMismatch, facade.answer(wrong, .once));
    wrong = prompt;
    wrong.verification.failures.hostname_mismatch = true;
    try std.testing.expectError(error.TrustChallengeMismatch, facade.answer(wrong, .once));
    wrong = prompt;
    wrong.authority.port = 443;
    try std.testing.expectError(error.TrustChallengeMismatch, facade.answer(wrong, .once));
    try std.testing.expectError(error.WrongOwner, store.facade(second_owner).answer(prompt, .once));
    try std.testing.expectEqual(tls.TrustSource.once, (try facade.answer(prompt, .once)).trusted.source);
    try std.testing.expectEqual(tls.TrustSource.once, (try facade.evaluate(op, authority, chain)).trusted.source);
    try std.testing.expect((try facade.evaluate(operation(owner, 11, 3), authority, chain)) == .challenge);
    try std.testing.expect((try facade.evaluate(op, .{ .host = "localhost", .port = 8443 }, chain)) == .challenge);
    verifier.failures.expired = true;
    const expired = (try facade.evaluate(op, authority, chain)).challenge;
    try std.testing.expect(expired.verification.failures.expired);
    store.cancelOperation(op);
    try std.testing.expectError(error.OperationRevoked, facade.answer(expired, .once));
}

test "BMC TLS replacement prompts retire stale prompts and unexceptable failures reject" {
    var verifier: FakeVerifier = .{};
    var store = tls.Store.init(a, verifier.verifier(), null);
    defer store.deinit();
    const facade = store.facade(owner);
    const old = (try facade.evaluate(op, authority, chain)).challenge;
    const changed = (try facade.evaluate(op, authority, &.{ "different-leaf", "same-intermediate" })).challenge;
    try std.testing.expectError(error.TrustChallengeMismatch, facade.answer(old, .once));
    try std.testing.expectEqual(tls.Denial.rejected, (try facade.answer(changed, .reject)).denied.reason);
    verifier.failures = .{ .revoked = true };
    try std.testing.expectEqual(tls.Denial.unexceptable_failure, (try facade.evaluate(op, authority, chain)).denied.reason);
    try std.testing.expectError(error.InvalidCertificateChain, facade.evaluate(op, authority, &.{}));
}

test "BMC TLS excessive validity is distinct from expiry and requires the exact exception scope" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(tls.FailureSet));
    try std.testing.expectEqual(@as(u32, 1 << 7), (tls.FailureSet{ .excessive_validity = true }).bits());
    var verifier: FakeVerifier = .{ .failures = .{ .untrusted_issuer = true, .hostname_mismatch = true, .excessive_validity = true } };
    var store = tls.Store.init(a, verifier.verifier(), null);
    defer store.deinit();
    const facade = store.facade(owner);
    const prompt = (try facade.evaluate(op, authority, chain)).challenge;
    try std.testing.expect(prompt.verification.failures.excessive_validity);
    try std.testing.expect(!prompt.verification.failures.expired);
    _ = try facade.answer(prompt, .once);
    try std.testing.expectEqual(tls.TrustSource.once, (try facade.evaluate(op, authority, chain)).trusted.source);
    try std.testing.expect((try facade.evaluate(operation(owner, 11, 3), authority, chain)) == .challenge);
    try std.testing.expect((try facade.evaluate(op, authority, &.{ "changed-leaf", "synthetic-intermediate" })) == .challenge);
    verifier.failures.excessive_validity = false;
    try std.testing.expect((try facade.evaluate(op, authority, chain)) == .challenge);
    verifier.failures = .{ .excessive_validity = true, .invalid_chain = true };
    try std.testing.expectEqual(tls.Denial.unexceptable_failure, (try facade.evaluate(op, authority, chain)).denied.reason);
    verifier.failures = .{ .excessive_validity = true, .revoked = true };
    try std.testing.expectEqual(tls.Denial.unexceptable_failure, (try facade.evaluate(op, authority, chain)).denied.reason);
    verifier.failures = @bitCast(@as(u32, (1 << 7) | (1 << 8)));
    try std.testing.expectEqual(tls.Denial.unexceptable_failure, (try facade.evaluate(op, authority, chain)).denied.reason);
}

test "BMC security owner and operation revocation cannot revive old facades or slow verification" {
    var verifier: FakeVerifier = .{};
    var store = tls.Store.init(a, verifier.verifier(), null);
    defer store.deinit();
    const facade = store.facade(owner);
    const prompt = (try facade.evaluate(op, authority, chain)).challenge;
    store.cancelOwner(owner);
    try std.testing.expectError(error.OwnerRevoked, facade.answer(prompt, .persistent));
    try std.testing.expectError(error.OwnerRevoked, facade.evaluate(operation(owner, 12, 3), authority, chain));
    const next_owner = try owner.nextGeneration();
    try std.testing.expect((try store.facade(next_owner).evaluate(operation(next_owner, 12, 3), authority, chain)) == .challenge);

    const CancellingVerifier = struct {
        fn verify(context: ?*anyopaque, _: tls.Authority, _: []const []const u8) !tls.VerificationResult {
            const target: *tls.Store = @ptrCast(@alignCast(context.?));
            target.cancelOwner(second_owner);
            return .{};
        }
    };
    var slow = tls.Store.init(a, .{ .verify = CancellingVerifier.verify }, null);
    defer slow.deinit();
    slow.verifier.context = &slow;
    try std.testing.expectError(error.OwnerRevoked, slow.facade(second_owner).evaluate(operation(second_owner, 11, 2), authority, chain));
    try std.testing.expectEqual(@as(usize, 0), slow.pending.items.len);

    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    const lease = (try arbiter.facade(owner).tryAcquire(resource("bmc.example"), op, 9)).lease;
    arbiter.cancelOperation(op);
    try std.testing.expectError(error.OperationRevoked, lease.revalidate(op, 9));
    try std.testing.expectError(error.OperationRevoked, arbiter.facade(owner).tryAcquire(resource("bmc.example"), op, 9));
    lease.release();
}

test "BMC security revocation allocation failure denies further actions" {
    var failing = std.testing.FailingAllocator.init(a, .{});
    var verifier: FakeVerifier = .{};
    var store = tls.Store.init(failing.allocator(), verifier.verifier(), null);
    defer store.deinit();
    const tls_facade = store.facade(second_owner);
    failing.fail_index = failing.alloc_index;
    store.cancelOwner(owner);
    try std.testing.expectError(error.SecurityRevocationCapacity, tls_facade.evaluate(operation(second_owner, 11, 1), authority, chain));
    var action_failing = std.testing.FailingAllocator.init(a, .{});
    var arbiter = actions.Arbiter.init(action_failing.allocator());
    defer arbiter.deinit();
    const action_facade = arbiter.facade(second_owner);
    action_failing.fail_index = action_failing.alloc_index;
    arbiter.releaseOwner(owner);
    try std.testing.expectError(error.SecurityRevocationCapacity, action_facade.tryAcquire(resource("bmc.example"), operation(second_owner, 1, 1), 9));
}

test "BMC TLS facade owner tampering cannot impersonate another owner after revocation" {
    var verifier: FakeVerifier = .{};
    var store = tls.Store.init(a, verifier.verifier(), null);
    defer store.deinit();
    var forged = store.facade(owner);
    const legitimate = store.facade(second_owner);
    const second_op = operation(second_owner, 66, 1);
    store.cancelOwner(owner);
    forged.owner = second_owner;
    try std.testing.expectError(error.WrongOwner, forged.evaluate(second_op, authority, chain));
    try std.testing.expectEqual(@as(usize, 0), verifier.calls);
    const prompt = (try legitimate.evaluate(second_op, authority, chain)).challenge;
    try std.testing.expectError(error.WrongOwner, forged.answer(prompt, .once));
    try std.testing.expectEqual(tls.TrustSource.once, (try legitimate.answer(prompt, .once)).trusted.source);
    try std.testing.expectEqual(tls.TrustSource.once, (try legitimate.evaluate(second_op, authority, chain)).trusted.source);
    forged.owner = owner;
    try std.testing.expectError(error.OwnerRevoked, forged.evaluate(op, authority, chain));
}

test "BMC secret facade owner tampering cannot read another owners authorized ref" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    const reference = "zw1_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const backend = memory.backend();
    try backend.add(backend.context, try credentials.scopeService(), reference, "synthetic-second-owner-secret");
    var store = secrets.Store.init(a);
    defer store.deinit();
    var forged = store.facade(owner);
    const legitimate = store.facade(second_owner);
    const second_op = operation(second_owner, 66, 1);
    try store.authorize(second_owner, second_op, reference);
    store.revokeOwner(owner);
    forged.owner = second_owner;
    try std.testing.expectError(error.WrongOwner, forged.acquire(second_op, reference, null));
    var lease = (try legitimate.acquire(second_op, reference, null)).lease;
    defer lease.deinit();
    try std.testing.expectEqualStrings("synthetic-second-owner-secret", try lease.bytes(second_owner, second_op, reference));
    forged.owner = owner;
    try std.testing.expect((try forged.acquire(op, reference, null)) == .ungranted);
}

test "BMC action facade and lease owner tampering cannot impersonate another owner" {
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    var forged = arbiter.facade(owner);
    const legitimate = arbiter.facade(second_owner);
    const second_op = operation(second_owner, 66, 1);
    arbiter.releaseOwner(owner);
    forged.owner = second_owner;
    try std.testing.expectError(error.WrongOwner, forged.tryAcquire(resource("bmc.example"), second_op, 9));
    const lease = (try legitimate.tryAcquire(resource("bmc.example"), second_op, 9)).lease;
    var forged_lease = lease;
    forged_lease.owner = owner;
    forged_lease.operation = op;
    try std.testing.expectError(error.WrongOwner, forged_lease.revalidate(op, 9));
    forged_lease.release();
    try lease.revalidate(second_op, 9);
    lease.release();
    forged.owner = owner;
    try std.testing.expectError(error.OwnerRevoked, forged.tryAcquire(resource("bmc.example"), op, 9));
}

test "BMC facade identity allocation failure is closed for all security services" {
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var verifier: FakeVerifier = .{};
    var store = tls.Store.init(failing.allocator(), verifier.verifier(), null);
    defer store.deinit();
    var secret_store = secrets.Store.init(failing.allocator());
    defer secret_store.deinit();
    var arbiter = actions.Arbiter.init(failing.allocator());
    defer arbiter.deinit();
    try std.testing.expectError(error.SecurityIdentityCapacity, store.facade(owner).evaluate(op, authority, chain));
    try std.testing.expectError(error.SecurityIdentityCapacity, secret_store.facade(owner).acquire(op, "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", null));
    try std.testing.expectError(error.SecurityIdentityCapacity, arbiter.facade(owner).tryAcquire(resource("bmc.example"), op, 9));
}

test "BMC facade identity capacity is bounded and existing owners retain their capabilities" {
    var verifier: FakeVerifier = .{ .failures = .{} };
    var store = tls.Store.init(a, verifier.verifier(), null);
    defer store.deinit();
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    for (0..4096) |index| {
        const handle: identity.SessionHandle = .{ .session_id = @fromBackingInt(index + 10000) };
        try std.testing.expect(store.facade(handle).context != null);
        try std.testing.expect(secret_store.facade(handle).context != null);
        try std.testing.expect(arbiter.facade(handle).context != null);
    }
    try std.testing.expectError(error.SecurityIdentityCapacity, store.facade(owner).evaluate(op, authority, chain));
    try std.testing.expectError(error.SecurityIdentityCapacity, secret_store.facade(owner).acquire(op, "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", null));
    try std.testing.expectError(error.SecurityIdentityCapacity, arbiter.facade(owner).tryAcquire(resource("bmc.example"), op, 9));
    const existing: identity.SessionHandle = .{ .session_id = @fromBackingInt(10000) };
    const existing_op = operation(existing, 99, 1);
    try std.testing.expect((try store.facade(existing).evaluate(existing_op, authority, chain)) == .trusted);
    try std.testing.expect((try secret_store.facade(existing).acquire(existing_op, "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", null)) == .ungranted);
    const lease = (try arbiter.facade(existing).tryAcquire(resource("bmc.example"), existing_op, 9)).lease;
    lease.release();
}

test "BMC persistent trust is durable scoped CAS and blocks changed leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
    const path = try std.fs.path.join(a, &.{ parent, "tls-pins" });
    defer a.free(path);
    var disk = try tls.FilePinStore.init(a, path);
    defer disk.deinit();
    var verifier: FakeVerifier = .{};
    var store = tls.Store.init(a, verifier.verifier(), disk.backend());
    const facade = store.facade(owner);
    const prompt = (try facade.evaluate(op, authority, chain)).challenge;
    try std.testing.expectEqual(tls.TrustSource.persistent_pin, (try facade.answer(prompt, .persistent)).trusted.source);
    store.deinit();
    // Recreate every in-memory trust object, and read the committed file.
    var reopened_disk = try tls.FilePinStore.init(a, path);
    defer reopened_disk.deinit();
    var reopened = tls.Store.init(a, verifier.verifier(), reopened_disk.backend());
    defer reopened.deinit();
    const new_facade = reopened.facade(second_owner);
    const new_op = operation(second_owner, 99, 1);
    try std.testing.expectEqual(tls.TrustSource.persistent_pin, (try new_facade.evaluate(new_op, authority, chain)).trusted.source);
    const changed = try new_facade.evaluate(new_op, authority, &.{ "new-leaf", "synthetic-intermediate" });
    try std.testing.expectEqual(tls.Denial.certificate_changed, changed.denied.reason);
    const b = reopened_disk.backend();
    const key = (try tls.canonicalize(authority)).digest();
    const saved = (try b.load(b.context, key)).?;
    try std.testing.expectError(error.TrustPinConflict, b.save(b.context, key, null, saved));
    // Additional identity failures are not inherited from the old approval.
    verifier.failures.hostname_mismatch = true;
    const scope = (try new_facade.evaluate(new_op, authority, chain)).challenge;
    try std.testing.expect(scope.scope_changed);
    try std.testing.expect(scope.verification.failures.hostname_mismatch);
    _ = try new_facade.answer(scope, .persistent);
    try std.testing.expect((try b.load(b.context, key)).?.exceptions.hostname_mismatch);
    verifier.failures.excessive_validity = true;
    const validity_scope = (try new_facade.evaluate(new_op, authority, chain)).challenge;
    try std.testing.expect(validity_scope.scope_changed);
    _ = try new_facade.answer(validity_scope, .persistent);
    const long_validity_pin = (try b.load(b.context, key)).?;
    try std.testing.expect(long_validity_pin.exceptions.excessive_validity);
    try std.testing.expect(!long_validity_pin.exceptions.expired);
    try std.testing.expectEqual(tls.TrustSource.persistent_pin, (try new_facade.evaluate(new_op, authority, chain)).trusted.source);
    var invalid_pin = long_validity_pin;
    invalid_pin.exceptions = @bitCast(@as(u32, 1 << 8));
    try b.save(b.context, key, long_validity_pin, invalid_pin);
    try std.testing.expectError(error.InvalidTrustPin, b.load(b.context, key));
}

test "web TLS pins survive store restart and require review after certificate rotation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const parent = path_buffer[0..try tmp.dir.realPath(std.testing.io, &path_buffer)];
    const path = try std.fs.path.join(a, &.{ parent, "tls-pins" });
    defer a.free(path);
    var disk = try tls.FilePinStore.init(a, path);
    defer disk.deinit();
    var verifier: FakeVerifier = .{};
    {
        var store = tls.Store.init(a, verifier.verifier(), disk.backend());
        defer store.deinit();
        const facade = store.facade(owner);
        const initial = (try facade.evaluateWeb(op, authority, chain)).challenge;
        _ = try facade.answer(initial, .persistent);
    }
    var store = tls.Store.init(a, verifier.verifier(), disk.backend());
    defer store.deinit();
    const facade = store.facade(second_owner);
    const key = operation(second_owner, 99, 1);
    try std.testing.expectEqual(.persistent_pin, (try facade.evaluateWeb(key, authority, chain)).trusted.source);
    try std.testing.expect((try facade.evaluate(key, authority, chain)) == .challenge);
    try std.testing.expect((try facade.evaluateWeb(key, .{ .host = authority.host, .port = 443 }, chain)) == .challenge);
    const rotated = &.{ "rotated-leaf", "synthetic-intermediate" };
    const prompt = (try facade.evaluateWeb(key, authority, rotated)).challenge;
    try std.testing.expect(prompt.scope_changed);
    _ = try facade.answer(prompt, .persistent);
    try std.testing.expectEqual(.persistent_pin, (try facade.evaluateWeb(key, authority, rotated)).trusted.source);
    verifier.failures.revoked = true;
    try std.testing.expectEqual(.unexceptable_failure, (try facade.evaluateWeb(key, authority, rotated)).denied.reason);
}

test "BMC persistent storage failure never grants trust" {
    var verifier: FakeVerifier = .{};
    var store = tls.Store.init(a, verifier.verifier(), null);
    defer store.deinit();
    const facade = store.facade(owner);
    const prompt = (try facade.evaluate(op, authority, chain)).challenge;
    try std.testing.expectError(error.PersistentTrustUnavailable, facade.answer(prompt, .persistent));
    try std.testing.expect((try facade.evaluate(op, authority, chain)) == .challenge);
    // A dedicated directory's parent must exist; no fallback to memory.
    var disk = try tls.FilePinStore.init(a, "/does-not-exist-zerowork-fixture/pins");
    defer disk.deinit();
    const b = disk.backend();
    const p: tls.Pin = .{ .leaf_fingerprint = @splat(1), .chain_fingerprint = @splat(2), .exceptions = .{ .untrusted_issuer = true } };
    try std.testing.expectError(error.TrustStorageFailure, b.save(b.context, @splat(3), null, p));
}

const ZeroObserver = struct {
    underlying: std.mem.Allocator,
    target: ?[*]u8 = null,
    observed_zero: bool = false,
    fn allocator(self: *ZeroObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn allocate(context: *anyopaque, size: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *ZeroObserver = @ptrCast(@alignCast(context));
        return self.underlying.rawAlloc(size, alignment, ret);
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) bool {
        const self: *ZeroObserver = @ptrCast(@alignCast(context));
        return self.underlying.rawResize(bytes, alignment, size, ret);
    }
    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, ret: usize) ?[*]u8 {
        const self: *ZeroObserver = @ptrCast(@alignCast(context));
        return self.underlying.rawRemap(bytes, alignment, size, ret);
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *ZeroObserver = @ptrCast(@alignCast(context));
        if (self.target == bytes.ptr) self.observed_zero = std.mem.allEqual(u8, bytes, 0);
        self.underlying.rawFree(bytes, alignment, ret);
    }
};

test "BMC secret refs require an operation grant and leases zero before allocator free" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tx = try credentials.Transaction.init();
    defer tx.deinit();
    const reference = (try tx.stage(std.testing.io, a, "synthetic-password-for-test", null)).?;
    defer a.free(reference);
    tx.commit();
    var observer: ZeroObserver = .{ .underlying = a };
    var store = secrets.Store.init(observer.allocator());
    defer store.deinit();
    const facade = store.facade(owner);
    try std.testing.expect((try facade.acquire(op, reference, null)) == .ungranted);
    try store.authorize(owner, op, reference);
    try std.testing.expectError(error.WrongOwner, store.facade(second_owner).acquire(op, reference, null));
    try std.testing.expect((try facade.acquire(operation(owner, 11, 3), reference, null)) == .ungranted);
    var lease = (try facade.acquire(op, reference, null)).lease;
    observer.target = lease.secret.ptr;
    try std.testing.expectEqualStrings("synthetic-password-for-test", try lease.bytes(owner, op, reference));
    try std.testing.expectError(error.SecretLeaseMismatch, lease.bytes(owner, operation(owner, 11, 3), reference));
    lease.deinit();
    lease.deinit();
    try std.testing.expect(observer.observed_zero);
    try std.testing.expectError(error.SecretLeaseReleased, lease.bytes(owner, op, reference));
    store.revokeOwner(owner);
    try std.testing.expect((try facade.acquire(op, reference, null)) == .ungranted);
}

test "BMC secret missing denied and cancellation stay structured" {
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var store = secrets.Store.init(a);
    defer store.deinit();
    const reference = "zw1_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const facade = store.facade(owner);
    try store.authorize(owner, op, reference);
    try std.testing.expect((try facade.acquire(op, reference, null)) == .missing);
    memory.denied = true;
    try std.testing.expect((try facade.acquire(op, reference, null)) == .denied);
    var cancelled: std.atomic.Value(bool) = .init(true);
    try std.testing.expect((try facade.acquire(op, reference, &cancelled)) == .cancelled);
    try std.testing.expect((try facade.acquire(op, "plaintext", null)) == .invalid_reference);
}

fn resource(host: []const u8) actions.ResourceKey {
    return .{ .authority = .{ .host = host }, .system_uri = "/redfish/v1/Systems/system-a", .system_id = "system-a", .verified_mapping = true, .capability_revision = 9 };
}
test "BMC actions coordinate tabs and power boot share a revision checked lease" {
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    const first = arbiter.facade(owner);
    const second = arbiter.facade(second_owner);
    const second_op = operation(second_owner, 12, 1);
    const lease = (try first.tryAcquire(resource("BMC-Fixture.Example."), op, 9)).lease;
    try lease.revalidate(op, 9);
    try std.testing.expectError(error.CapabilityRevisionChanged, lease.revalidate(op, 10));
    try std.testing.expectError(error.StaleOperation, lease.revalidate(operation(owner, 11, 3), 9));
    const busy = (try second.tryAcquire(resource("bmc-fixture.example"), second_op, 9)).busy;
    try std.testing.expect(busy.eql(op));
    // Lock identity does not refer to any transport/session from the other tab.
    const independent = (try second.tryAcquire(resource("different-bmc.example"), second_op, 9)).lease;
    independent.release();
    lease.release();
    lease.release();
    try std.testing.expectError(error.ActionLeaseReleased, lease.revalidate(op, 9));
    const next = (try second.tryAcquire(resource("bmc-fixture.example"), second_op, 9)).lease;
    lease.release();
    try next.revalidate(second_op, 9);
    arbiter.releaseOwner(second_owner);
    try std.testing.expectEqual(@as(usize, 0), arbiter.count());
    try std.testing.expectError(error.OwnerRevoked, next.revalidate(second_op, 9));
    try std.testing.expectError(error.OwnerRevoked, second.tryAcquire(resource("bmc-fixture.example"), operation(second_owner, 15, 1), 9));
}

test "BMC action keys reject ambiguous system identities unverified mappings and wrong owners" {
    var arbiter = actions.Arbiter.init(a);
    defer arbiter.deinit();
    const facade = arbiter.facade(owner);
    try std.testing.expectError(error.WrongOwner, facade.tryAcquire(resource("bmc.example"), operation(second_owner, 1, 1), 9));
    var key = resource("bmc.example");
    key.verified_mapping = false;
    try std.testing.expectError(error.UnverifiedSystem, facade.tryAcquire(key, op, 9));
    key.verified_mapping = true;
    try std.testing.expectError(error.CapabilityRevisionChanged, facade.tryAcquire(key, op, 8));
    for ([_][]const u8{ "https://elsewhere.example/System/1", "//elsewhere/System/1", "/System/../1", "/System/%31", "/System/1?other", "/System/1/" }) |uri| {
        key.system_uri = uri;
        try std.testing.expectError(error.InvalidSystemUri, facade.tryAcquire(key, op, 9));
    }
    key = resource("bmc.example");
    const lease = (try facade.tryAcquire(key, op, 9)).lease;
    defer lease.release();
    key.system_id = "different-id-for-same-uri";
    try std.testing.expect((try facade.tryAcquire(key, operation(owner, 12, 1), 9)) == .busy);
    key = resource("bmc.example");
    key.system_uri = "/other/path-for-same-system-id";
    try std.testing.expect((try facade.tryAcquire(key, operation(owner, 12, 1), 9)) == .busy);
}

// Public synthetic ECDSA certificates. The ephemeral private key was discarded.
// The valid certificate spans 2026-10-01 to 2027-10-01; refresh this fixture
// after expiry instead of weakening the platform's real-time date validation.
const valid_cert_b64 = "MIIBpjCCAUugAwIBAgIBATAKBggqhkjOPQQDAjAeMRwwGgYDVQQDDBNibWMtZml4dHVyZS5leGFtcGxlMB4XDTI2MTAwMTAwMDAwMFoXDTI3MTAwMTAwMDAwMFowHjEcMBoGA1UEAwwTYm1jLWZpeHR1cmUuZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABDQP9hf9Vk+yUsRqsYb+wGAY220AZ2JD7XUDC+pYiMQm3byGJ347PqR7QOUiG+TbHLmQgEPwfM2Dpd5vecC4SryjejB4MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCQGA1UdEQQdMBuCE2JtYy1maXh0dXJlLmV4YW1wbGWHBMAAAiwwHQYDVR0OBBYEFIB84U8SHip9Su+cw9+qTE7L1xUYMAoGCCqGSM49BAMCA0kAMEYCIQD5fsRc6a1l1ZJUi4t34ch8EFj66n7wy6VAUtyggTvYsQIhAJu29BL7/qpdVZY1BhnSJLY9iv0K+QYr9CgGpUhToKgC";
const expired_cert_b64 = "MIIBpDCCAUugAwIBAgIBAjAKBggqhkjOPQQDAjAeMRwwGgYDVQQDDBNibWMtZml4dHVyZS5leGFtcGxlMB4XDTE4MDEwMTAwMDAwMFoXDTE5MDEwMTAwMDAwMFowHjEcMBoGA1UEAwwTYm1jLWZpeHR1cmUuZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABLDT0kNGDaGuBdJpl7knWYvOSiy45Aws01Ecig/THTlXO3r4N5edJE0L77l1U28BdDmqUk0XTEjlihBweyjGgKOjejB4MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCQGA1UdEQQdMBuCE2JtYy1maXh0dXJlLmV4YW1wbGWHBMAAAiwwHQYDVR0OBBYEFDuh5juHvRtjCx7gO7o81IXuU9/PMAoGCCqGSM49BAMCA0cAMEQCIFhfcBt/EujhCLMS2MROpEPNhpwcgyK+ssQ19V+k0w1BAiA+EKqCB6iFQetnnXuqqEr+O7flhklv7Mfv3XtSfm0STg==";
// Synthetic equivalent of a ten-year validity interval, not a device cert.
const excessive_validity_cert_b64 = "MIIBpjCCAUugAwIBAgIBATAKBggqhkjOPQQDAjAeMRwwGgYDVQQDDBNibWMtZml4dHVyZS5leGFtcGxlMB4XDTIwMTAzMTA4MjAxNloXDTMwMTAyOTA4MjAxNlowHjEcMBoGA1UEAwwTYm1jLWZpeHR1cmUuZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABDgSouxUPNWPWtyLHhxHOQeHOTkMSIZ4Yj8JBj8y9HYCjMNVbIxwzrSvR2Yq8jOotcvEMdhcsiIzoK81o0Hbp8OjejB4MAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMCQGA1UdEQQdMBuCE2JtYy1maXh0dXJlLmV4YW1wbGWHBMAAAiwwHQYDVR0OBBYEFLNMDUcYaGsVHbBl1DbRRi+RGmA3MAoGCCqGSM49BAMCA0kAMEYCIQCKODox5GVKg3TV6tXutmBFF70A5NKKfht+qzj0MIdttAIhAM1limM70Zhzi3KQDqp/Vwh/amSIN2kS5AjalXPP+vkA";
fn decodeCertificate(base64: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const bytes = try a.alloc(u8, try decoder.calcSizeForSlice(base64));
    errdefer a.free(bytes);
    try decoder.decode(bytes, base64);
    return bytes;
}
test "BMC macOS TLS verification uses original SSL host and separates self signed expiry and SAN mismatch" {
    const valid = try decodeCertificate(valid_cert_b64);
    defer a.free(valid);
    const expired = try decodeCertificate(expired_cert_b64);
    defer a.free(expired);
    const verifier = tls.Verifier.native();
    const good_name = try verifier.verify(null, .{ .host = "bmc-fixture.example" }, &.{valid});
    try std.testing.expect(good_name.failures.untrusted_issuer);
    try std.testing.expect(!good_name.failures.hostname_mismatch);
    try std.testing.expect(!good_name.failures.expired);
    try std.testing.expect(!good_name.failures.excessive_validity);
    try std.testing.expect(good_name.failures.canExcept());
    try std.testing.expect(good_name.not_before_unix > 0);
    try std.testing.expect(good_name.not_after_unix > good_name.not_before_unix);
    try std.testing.expect(good_name.subjectText().len > 0);
    try std.testing.expect(good_name.issuerText().len > 0);
    const ip_san = try verifier.verify(null, .{ .host = "192.0.2.44" }, &.{valid});
    try std.testing.expect(!ip_san.failures.hostname_mismatch);
    const mismatch = try verifier.verify(null, .{ .host = "localhost" }, &.{valid});
    try std.testing.expect(mismatch.failures.hostname_mismatch);
    const old = try verifier.verify(null, .{ .host = "bmc-fixture.example" }, &.{expired});
    try std.testing.expect(old.failures.expired);
    try std.testing.expect(!old.failures.hostname_mismatch);
    const both = try verifier.verify(null, .{ .host = "wrong.example" }, &.{expired});
    try std.testing.expect(both.failures.expired and both.failures.hostname_mismatch);
    const invalid = try verifier.verify(null, .{ .host = "bmc-fixture.example" }, &.{"not DER"});
    try std.testing.expect(invalid.failures.invalid_chain);
}

test "BMC macOS TLS excessive certificate validity is a scoped policy failure and not expiry" {
    const certificate = try decodeCertificate(excessive_validity_cert_b64);
    defer a.free(certificate);
    const verifier = tls.Verifier.native();
    const result = try verifier.verify(null, .{ .host = "bmc-fixture.example" }, &.{certificate});
    try std.testing.expectEqual(@as(i32, -67901), result.native_status);
    try std.testing.expect(result.failures.excessive_validity);
    try std.testing.expect(result.failures.untrusted_issuer);
    try std.testing.expect(!result.failures.expired and !result.failures.not_yet_valid);
    try std.testing.expect(!result.failures.invalid_chain);
    try std.testing.expect(result.failures.canExcept());
    const mismatch = try verifier.verify(null, .{ .host = "wrong.example" }, &.{certificate});
    try std.testing.expect(mismatch.failures.excessive_validity and mismatch.failures.hostname_mismatch);
    try std.testing.expect(!mismatch.failures.expired and !mismatch.failures.invalid_chain);
    try std.testing.expect(mismatch.failures.canExcept());
    var store = tls.Store.init(a, verifier, null);
    defer store.deinit();
    const facade = store.facade(owner);
    const target: tls.Authority = .{ .host = "bmc-fixture.example" };
    const prompt = (try facade.evaluate(op, target, &.{certificate})).challenge;
    try std.testing.expect(prompt.verification.failures.excessive_validity);
    _ = try facade.answer(prompt, .once);
    try std.testing.expectEqual(tls.TrustSource.once, (try facade.evaluate(op, target, &.{certificate})).trusted.source);
}
