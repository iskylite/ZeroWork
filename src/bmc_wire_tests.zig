const std = @import("std");
const http = @import("plugins/bmc_ikvm/protocol/http.zig");
const ws = @import("plugins/bmc_ikvm/protocol/websocket.zig");
const tls = @import("plugins/bmc_ikvm/protocol/tls.zig");
const profile = @import("plugins/bmc_ikvm/protocol/profile.zig");
const a = std.testing.allocator;

fn fragmentedResponse(bytes: []const u8) !void {
    for (0..bytes.len + 1) |cut| {
        var parser = http.ResponseParser.init(a, .{});
        defer parser.deinit();
        try std.testing.expectEqual(cut, try parser.feed(bytes[0..cut]));
        try std.testing.expectEqual(bytes.len - cut, try parser.feed(bytes[cut..]));
        try std.testing.expect(parser.isDone());
        try std.testing.expectEqual(@as(u16, 200), parser.status);
        try std.testing.expectEqualStrings("hello", parser.body());
    }
}

test "BMC HTTP content length and chunked parse at every split point" {
    try fragmentedResponse("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nX-Test: ok\r\n\r\nhello");
    try fragmentedResponse("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;foo=bar\r\nhe\r\n3\r\nllo\r\n0\r\nX-End: yes\r\n\r\n");
}

test "BMC HTTP byte fragments, interim response and exact body consumption" {
    var p = http.ResponseParser.init(a, .{});
    defer p.deinit();
    const header = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n";
    for (header) |ch| try std.testing.expectEqual(@as(usize, 1), try p.feed(&.{ch}));
    try std.testing.expectEqual(@as(usize, 5), try p.feed("helloNEXT"));
    try std.testing.expectEqualStrings("hello", p.body());
    try std.testing.expectEqual(@as(usize, 0), try p.feed("NEXT"));
}

test "BMC HTTP EOF and no-body response rules" {
    var p = http.ResponseParser.init(a, .{});
    defer p.deinit();
    _ = try p.feed("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello");
    try std.testing.expect(!p.isDone());
    try p.finishEof();
    try std.testing.expect(p.isDone());
    var short = http.ResponseParser.init(a, .{});
    defer short.deinit();
    _ = try short.feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhi");
    try std.testing.expectError(error.TruncatedResponse, short.finishEof());
    var head = http.ResponseParser.init(a, .{ .request_is_head = true });
    defer head.deinit();
    const h = "HTTP/1.1 200 OK\r\nContent-Length: 9000000\r\n\r\n";
    try std.testing.expectEqual(h.len, try head.feed(h ++ "NEXT"));
}

test "BMC HTTP rejects ambiguous framing and invalid header injection" {
    const cases = [_][]const u8{
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 1, 1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\n",
    };
    for (cases) |bytes| {
        var p = http.ResponseParser.init(a, .{});
        defer p.deinit();
        try std.testing.expectError(error.ConflictingFraming, p.feed(bytes));
    }
    var p = http.ResponseParser.init(a, .{});
    defer p.deinit();
    try std.testing.expectError(error.InvalidHeader, p.feed("HTTP/1.1 200 OK\r\n folded: value\r\n\r\n"));
    var te = http.ResponseParser.init(a, .{});
    defer te.deinit();
    try std.testing.expectError(error.UnsupportedTransferEncoding, te.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"));
}

test "BMC HTTP enforces bounded headers REST body chunks and trailers" {
    var headers = http.ResponseParser.init(a, .{ .header_bytes = 16 });
    defer headers.deinit();
    try std.testing.expectError(error.HeadersTooLarge, headers.feed("HTTP/1.1 200 OK\r\nX: y\r\n\r\n"));
    var fixed = http.ResponseParser.init(a, .{ .body_bytes = 4 });
    defer fixed.deinit();
    try std.testing.expectError(error.BodyTooLarge, fixed.feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"));
    var chunked = http.ResponseParser.init(a, .{ .body_bytes = 4 });
    defer chunked.deinit();
    try std.testing.expectError(error.BodyTooLarge, chunked.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n"));
    var trailer = http.ResponseParser.init(a, .{});
    defer trailer.deinit();
    try std.testing.expectError(error.ConflictingFraming, trailer.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 0\r\n\r\n"));
    var eof = http.ResponseParser.init(a, .{ .body_bytes = 4 });
    defer eof.deinit();
    try std.testing.expectError(error.BodyTooLarge, eof.feed("HTTP/1.1 200 OK\r\n\r\n12345"));
}

test "BMC HTTP origin preserves remote identity and rejects cross-origin references" {
    const origin: http.Origin = .{ .host = "bmc.fixture.test", .port = 8443 };
    try std.testing.expectEqualStrings("/redfish/v1/", try origin.validateReference("https://BMC.FIXTURE.TEST:8443/redfish/v1/"));
    try std.testing.expectEqualStrings("/redfish/v1/", try origin.validateReference("/redfish/v1/"));
    try std.testing.expectError(error.CrossOriginReference, origin.validateReference("https://localhost:8443/redfish/v1/"));
    try std.testing.expectError(error.CrossOriginReference, origin.validateReference("http://bmc.fixture.test:8443/redfish/v1/"));
    try std.testing.expectError(error.CrossOriginReference, origin.validateReference("https://bmc.fixture.test/redfish/v1/"));
    try std.testing.expectError(error.InvalidPath, origin.validateReference("//evil.test/path"));
    try std.testing.expectError(error.InvalidAuthority, origin.validateReference("https://user@bmc.fixture.test:8443/path"));
    try std.testing.expectError(error.InvalidPath, origin.validateReference("/x%0d%0aHost:evil"));
    const ip: http.Origin = .{ .host = "::1" };
    try std.testing.expectEqualStrings("/redfish/v1/", try ip.validateReference("https://[::1]:443/redfish/v1/"));
}

test "BMC HTTP request builder owns Host/framing and supports short writes" {
    const origin: http.Origin = .{ .host = "bmc.fixture.test", .port = 8443 };
    const request = try http.buildRequest(a, "POST", origin, "/redfish/v1/SessionService/Sessions", &.{.{ .name = "From", .value = "WebUI" }}, "{}");
    defer a.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "Host: bmc.fixture.test:8443\r\n") != null);
    var cursor: http.WriteCursor = .{ .bytes = request };
    while (!cursor.done()) try cursor.advance(@min(@as(usize, 3), cursor.remaining().len));
    try std.testing.expectError(error.InvalidWriteCount, cursor.advance(1));
    try std.testing.expectError(error.InvalidHeader, http.buildRequest(a, "GET", origin, "/", &.{.{ .name = "X", .value = "ok\r\nInjected: yes" }}, ""));
    try std.testing.expectError(error.ReservedHeader, http.buildRequest(a, "GET", origin, "/", &.{.{ .name = "Host", .value = "evil.test" }}, ""));
    try std.testing.expectError(error.InvalidAuthority, http.buildRequest(a, "GET", .{ .host = "x\r\nEvil:y" }, "/", &.{}, ""));
}

const Events = struct {
    data: std.ArrayList(u8) = .empty,
    ping: usize = 0,
    pong: usize = 0,
    close: usize = 0,
    close_code: ?u16 = null,
    pub fn onEvent(self: *Events, event: ws.Event) !void {
        switch (event) {
            .binary => |bytes| try self.data.appendSlice(a, bytes),
            .ping => self.ping += 1,
            .pong => self.pong += 1,
            .close => |c| {
                self.close += 1;
                self.close_code = c.code;
            },
        }
    }
};

test "BMC WS upgrade verifies RFC accept status subprotocol and no extensions" {
    const upgrade: ws.Upgrade = .{ .key = "dGhlIHNhbXBsZSBub25jZQ==".*, .subprotocol = "synthetic-kvm-token" };
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &ws.acceptForKey(&upgrade.key));
    var response = http.ResponseParser.init(a, .{});
    defer response.deinit();
    const raw = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: synthetic-kvm-token\r\n\r\n";
    try std.testing.expectEqual(raw.len, try response.feed(raw ++ "RFB"));
    try upgrade.validate(&response);
    const wrong: ws.Upgrade = .{ .key = upgrade.key, .subprotocol = "different-token" };
    try std.testing.expectError(error.InvalidSubprotocol, wrong.validate(&response));
    const request = try upgrade.buildRequest(a, .{ .host = "bmc.fixture.test" }, "/kvm/0");
    defer a.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "GET /kvm/0 HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "/kvm/0?synthetic-kvm-token") == null);
    try std.testing.expectError(error.InvalidSubprotocol, ws.Upgrade.init("a,b"));
}

test "BMC WS fragmented binary permits ping pong and close interleaving at every split" {
    const bytes = "\x02\x02RF\x89\x01p\x80\x02B \x8a\x01p\x82\x03abc\x88\x02\x03\xe8";
    for (0..bytes.len + 1) |cut| {
        var p: ws.Parser = .{};
        var events: Events = .{};
        defer events.data.deinit(a);
        try std.testing.expectEqual(cut, try p.feed(bytes[0..cut], &events));
        try std.testing.expectEqual(bytes.len - cut, try p.feed(bytes[cut..], &events));
        try std.testing.expectEqualStrings("RFB abc", events.data.items);
        try std.testing.expectEqual(@as(usize, 1), events.ping);
        try std.testing.expectEqual(@as(usize, 1), events.pong);
        try std.testing.expectEqual(@as(?u16, 1000), events.close_code);
        try p.finishEof();
    }
}

test "BMC WS client uses fresh random masks and reconstructs all payload lengths" {
    for ([_]usize{ 0, 5, 125, 126, 65535, 65536 }) |len| {
        const payload = try a.alloc(u8, len);
        defer a.free(payload);
        @memset(payload, 0xa5);
        const first = try ws.clientFrame(a, .binary, true, payload);
        defer a.free(first);
        const second = try ws.clientFrame(a, .binary, true, payload);
        defer a.free(second);
        const mask_offset: usize = if (len < 126) 2 else if (len <= 65535) 4 else 10;
        try std.testing.expect(first[1] & 128 != 0);
        try std.testing.expect(!std.mem.eql(u8, first[mask_offset..][0..4], second[mask_offset..][0..4]));
        for (payload, 0..) |ch, i| try std.testing.expectEqual(ch, first[mask_offset + 4 + i] ^ first[mask_offset + i % 4]);
    }
}

test "BMC WS rejects RSV masking unknown opcodes illegal continuation control length and close" {
    const Case = struct { bytes: []const u8, failure: anyerror };
    const cases = [_]Case{
        .{ .bytes = "\xc2\x00", .failure = error.UnnegotiatedExtension },
        .{ .bytes = "\x82\x80", .failure = error.MaskedServerFrame },
        .{ .bytes = "\x83\x00", .failure = error.UnknownOpcode },
        .{ .bytes = "\x80\x00", .failure = error.UnexpectedContinuation },
        .{ .bytes = "\x02\x00\x82\x00", .failure = error.InterleavedDataMessage },
        .{ .bytes = "\x09\x00", .failure = error.InvalidControlFrame },
        .{ .bytes = "\x89\x7e\x00\x7e", .failure = error.InvalidControlFrame },
        .{ .bytes = "\x82\x7e\x00\x01", .failure = error.NonCanonicalLength },
        .{ .bytes = "\x82\x7f\x80\x00\x00\x00\x00\x01\x00\x00", .failure = error.NonCanonicalLength },
        .{ .bytes = "\x88\x01x", .failure = error.InvalidClose },
        .{ .bytes = "\x88\x02\x03\xed", .failure = error.InvalidClose },
        .{ .bytes = "\x88\x03\x03\xe8\xff", .failure = error.InvalidClose },
    };
    for (cases) |case| {
        var p: ws.Parser = .{};
        var events: Events = .{};
        defer events.data.deinit(a);
        try std.testing.expectError(case.failure, p.feed(case.bytes, &events));
    }
}

test "BMC WS streams legal Raw-sized payload above 8 MiB with constant parser storage" {
    var p: ws.Parser = .{};
    const Counter = struct {
        count: usize = 0,
        pub fn onEvent(self: *@This(), event: ws.Event) !void {
            switch (event) {
                .binary => |bytes| self.count += bytes.len,
                else => return error.UnexpectedEvent,
            }
        }
    };
    var sink: Counter = .{};
    const size: usize = 4096 * 2160 * 4;
    var header: [10]u8 = .{ 0x82, 127, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, header[2..10], size, .big);
    _ = try p.feed(&header, &sink);
    var chunk: [65536]u8 = undefined;
    @memset(&chunk, 0);
    while (sink.count < size) _ = try p.feed(chunk[0..@min(chunk.len, size - sink.count)], &sink);
    try std.testing.expectEqual(size, sink.count);
    try std.testing.expect(@sizeOf(ws.Parser) < 512);
}

fn syntheticIdentity() profile.Identity {
    return .{ .trusted_channel = true, .manufacturer = "Sugon", .product = "SuperPod", .processor_vendor = "Hygon", .bmc_chip = "AST2600-A3", .firmware = "1.80", .oem_namespace = "Public", .kvm_login_resource = profile.kvm_login_path, .oem_rfb = true };
}

test "BMC fixed Sugon profile accepts only trusted exact firmware and reviewed evidence" {
    var identity = syntheticIdentity();
    try std.testing.expectEqual(profile.Id.sugon_1_80_oem_rfb, try profile.detect(identity));
    const selected = try profile.select(identity);
    try selected.validateForProduction();
    try std.testing.expect(!selected.synthetic);
    var missing = selected;
    missing.evidence.public_key_pem = "";
    try std.testing.expectError(error.ProfileEvidenceMissing, missing.validateForProduction());
    identity.manufacturer = "N/A";
    try std.testing.expectError(error.UnsupportedProfile, profile.select(identity));
    identity.manufacturer = "Sugon";
    identity.firmware = "1.81";
    try std.testing.expectError(error.UnsupportedProfile, profile.select(identity));
    identity.trusted_channel = false;
    try std.testing.expectError(error.UntrustedProfileInput, profile.select(identity));
}

test "BMC embedded Sugon public material hashes and minimal schema remain fixed" {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(profile.sugon_public_key_pem, &actual, .{});
    try std.testing.expectEqualSlices(u8, &profile.sugon_public_key_sha256, &actual);
    std.crypto.hash.sha2.Sha256.hash(profile.sugon_public_fixture, &actual, .{});
    try std.testing.expectEqualSlices(u8, &profile.sugon_fixture_sha256, &actual);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, profile.sugon_public_fixture, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const material = root.get("public_material").?.object;
    try std.testing.expectEqualStrings("4470c19b553d1e64cf529c1709843ce334b110501d090b4dc02c2a2e74ca95c7", material.get("source_sha256").?.string);
    try std.testing.expectEqualStrings("3f3bd3f8a4837161f4dff9c6cce1110d38b2eb1d873d39c6c1d33173eccd71d6", material.get("public_key_sha256").?.string);
    try std.testing.expectEqualStrings("1.80", root.get("identity").?.object.get("firmware").?.string);
    const common = root.get("rest_common_headers").?.object;
    try std.testing.expectEqualStrings("WebUI", common.get("From").?.string);
    try std.testing.expectEqualStrings("XMLHttpRequest", common.get("X-Requested-With").?.string);
    try std.testing.expect(root.get("kvm_session").?.object.get("error_codes").?.array.items.len == 0);
    const deletion = root.get("logout").?.object.get("kvm").?.object;
    try std.testing.expectEqual(@as(i64, 200), deletion.get("status").?.integer);
    try std.testing.expectEqualStrings("Base.1.19.Success", deletion.get("message_id").?.string);
    try std.testing.expectEqualStrings("OK", deletion.get("severity").?.string);
    const limits = root.get("verification_limits").?.object;
    for ([_][]const u8{ "management_writes_verified", "boot_writes_verified", "remote_input_effects_verified", "dynamic_tight_verified" }) |name|
        try std.testing.expect(!limits.get(name).?.bool);
    const encrypted = try tls.encryptRsa2048(a, profile.sugon_public_key_pem, "synthetic-password");
    defer {
        std.crypto.secureZero(u8, encrypted);
        a.free(encrypted);
    }
    try std.testing.expectEqual(@as(usize, 256), encrypted.len);
}

test "BMC production profile rejects substituted key digest fixture and logout rule" {
    const selected = try profile.select(syntheticIdentity());
    var altered = selected;
    altered.evidence.public_key_pem = "substituted-public-key";
    try std.testing.expectError(error.ProfileEvidenceMismatch, altered.validateForProduction());
    // Updating the supplied digest cannot authorize another public key.
    std.crypto.hash.sha2.Sha256.hash(altered.evidence.public_key_pem, &altered.evidence.public_key_sha256, .{});
    try std.testing.expectError(error.ProfileEvidenceMismatch, altered.validateForProduction());
    altered = selected;
    altered.evidence.identity_fixture_sha256 = @splat(2);
    try std.testing.expectError(error.ProfileEvidenceMismatch, altered.validateForProduction());
    altered = selected;
    altered.evidence.kvm_logout = .own_session_location;
    try std.testing.expectError(error.ProfileEvidenceMismatch, altered.validateForProduction());
    const own_uri = try profile.logoutReference(a, .{ .host = "bmc.fixture.test" }, selected.evidence.kvm_logout.?, null, "fixture-owned-kvm-id");
    defer a.free(own_uri);
    try std.testing.expectEqualStrings(profile.kvm_login_path ++ "/fixture-owned-kvm-id", own_uri);
}

test "BMC synthetic profile cannot pass production release and logout never guesses URI" {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("synthetic-public-key", &hash, .{});
    const fixture = try profile.syntheticForTest(syntheticIdentity(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = "synthetic-public-key", .public_key_sha256 = hash, .public_key_source = "synthetic fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .{ .own_id_template = .{ .prefix = "/synthetic/kvm/", .suffix = "" } } });
    try std.testing.expectError(error.SyntheticProfileForbidden, fixture.validateForProduction());
    const origin: http.Origin = .{ .host = "bmc.fixture.test" };
    try std.testing.expectError(error.SessionLocationMissing, profile.logoutReference(a, origin, .own_session_location, null, "1"));
    try std.testing.expectError(error.CrossOriginReference, profile.logoutReference(a, origin, .own_session_location, "https://evil.test/session/1", "1"));
    const path = try profile.logoutReference(a, origin, .{ .own_id_template = .{ .prefix = "/synthetic/kvm/", .suffix = "" } }, null, "own-fixture");
    defer a.free(path);
    try std.testing.expectEqualStrings("/synthetic/kvm/own-fixture", path);
}

test "BMC RSA refuses missing malformed keys and plaintext beyond PKCS1v15 limit" {
    try std.testing.expectError(error.ProfileEvidenceMissing, tls.encryptPassword(a, "", "synthetic-password"));
    try std.testing.expectError(error.InvalidPublicKey, tls.encryptPassword(a, "not a key", "synthetic-password"));
    var too_long: [246]u8 = undefined;
    @memset(&too_long, 'x');
    try std.testing.expectError(error.PasswordTooLong, tls.encryptPassword(a, "not a key", &too_long));
}

fn pollTls(fd: c_int, state: tls.Step) !void {
    var fds = [_]std.c.pollfd{.{ .fd = fd, .events = if (state == .want_write) std.c.POLL.OUT else std.c.POLL.IN, .revents = 0 }};
    if (std.c.poll(&fds, 1, 200) < 0) return error.PollFailed;
}

fn writeTlsSmall(client: *tls.Client, fd: c_int, bytes: []const u8) !void {
    var cursor: http.WriteCursor = .{ .bytes = bytes };
    var attempts: usize = 0;
    while (!cursor.done()) {
        attempts += 1;
        if (attempts > 1000) return error.FixtureTimeout;
        const pending = cursor.remaining()[0..@min(cursor.remaining().len, 7)];
        switch (try client.write(pending)) {
            .bytes => |count| try cursor.advance(count),
            .progress => |state| switch (state) {
                .want_read, .want_write => try pollTls(fd, state),
                else => return error.UnexpectedTlsState,
            },
        }
    }
}

const tls_fixture_server =
    \\import base64,pathlib,socket,ssl,subprocess,sys,tempfile
    \\with tempfile.TemporaryDirectory(prefix='zerowork-bmc-tls-') as directory:
    \\    d=pathlib.Path(directory)
    \\    config='[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=bmc.fixture.test\n[extensions]\nsubjectAltName=DNS:bmc.fixture.test,IP:127.0.0.1\n'
    \\    (d/'cert.cnf').write_text(config)
    \\    subprocess.run(['/usr/bin/openssl','req','-new','-x509','-newkey','rsa:2048','-nodes','-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem'),'-days','1','-config',str(d/'cert.cnf')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    \\    public=subprocess.run(['/usr/bin/openssl','pkey','-in',str(d/'key.pem'),'-pubout'],capture_output=True,check=True).stdout
    \\    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    \\    context.load_cert_chain(d/'cert.pem',d/'key.pem')
    \\    raw=socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=5)
    \\    with context.wrap_socket(raw,server_side=True) as stream:
    \\        stream.settimeout(.2)
    \\        try: early=stream.recv(1)
    \\        except (TimeoutError,socket.timeout): early=b''
    \\        assert early==b'', 'application bytes preceded trust decision'
    \\        stream.settimeout(5)
    \\        stream.sendall(public+b'ENDPUB\n')
    \\        def take(length):
    \\            out=b''
    \\            while len(out)<length:
    \\                chunk=stream.recv(min(11,length-len(out)))
    \\                assert chunk, 'unexpected EOF'
    \\                out+=chunk
    \\            return out
    \\        first=take(256)
    \\        second=base64.b64decode(take(344),validate=True)
    \\        assert len(second)==256 and first!=second
    \\        for ciphertext in (first,second):
    \\            result=subprocess.run(['/usr/bin/openssl','pkeyutl','-decrypt','-inkey',str(d/'key.pem'),'-pkeyopt','rsa_padding_mode:pkcs1'],input=ciphertext,capture_output=True,check=True)
    \\            assert result.stdout==b'synthetic-password'
    \\        for byte in b'fixture-response': stream.sendall(bytes([byte]))
    \\        stream.unwrap()
;

test "BMC TLS actual local handshake trust gate DER RSA partial IO and clean close" {
    const listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (listener < 0) return error.SocketFailed;
    defer _ = std.c.close(listener);
    var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or std.c.listen(listener, 1) != 0) return error.ListenFailed;
    var address_len: std.c.socklen_t = @sizeOf(@TypeOf(address));
    if (std.c.getsockname(listener, @ptrCast(&address), &address_len) != 0) return error.AddressFailed;
    const port = try std.fmt.allocPrint(a, "{d}", .{std.mem.bigToNative(u16, address.port)});
    defer a.free(port);
    var child = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/usr/bin/python3", "-c", tls_fixture_server, port } });
    defer if (child.id != null) child.kill(std.testing.io);
    var pending = [_]std.c.pollfd{.{ .fd = listener, .events = std.c.POLL.IN, .revents = 0 }};
    if (std.c.poll(&pending, 1, 10000) <= 0) return error.FixtureTimeout;
    const fd = std.c.accept(listener, null, null);
    if (fd < 0) return error.AcceptFailed;
    defer _ = std.c.close(fd);
    var client = try tls.Client.init(fd, "bmc.fixture.test");
    defer client.deinit();
    try std.testing.expectEqualStrings("bmc.fixture.test", client.originalHost());
    var handshaken = false;
    for (0..100) |_| {
        const state = try client.handshakeStep();
        if (state == .needs_trust) {
            handshaken = true;
            break;
        }
        if (state != .want_read and state != .want_write) return error.UnexpectedTlsState;
        try pollTls(fd, state);
    }
    try std.testing.expect(handshaken);
    const chain = try client.peerChain(a);
    defer a.free(chain);
    try std.testing.expectEqual(@as(usize, 1), chain.len);
    try std.testing.expect(chain[0].len > 500 and chain[0][0] == 0x30);
    // Self-signed is diagnostic, never implicit authorization.
    try std.testing.expect(client.verificationFlags() != 0);
    try std.testing.expectEqual(tls.Step.needs_trust, (try client.write("synthetic-password")).progress);
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(tls.Step.needs_trust, (try client.read(&small)).progress);
    // Let the fixture verify that no credential arrived while trust was pending.
    _ = std.c.poll(&pending, 0, 300);
    try client.authorizeTrust(true);
    var public: std.ArrayList(u8) = .empty;
    defer public.deinit(a);
    var got_public = false;
    for (0..2000) |_| {
        switch (try client.read(&small)) {
            .bytes => |count| try public.appendSlice(a, small[0..count]),
            .progress => |state| switch (state) {
                .want_read, .want_write => try pollTls(fd, state),
                else => return error.UnexpectedTlsState,
            },
        }
        if (public.items.len > 16384) return error.FixtureTooLarge;
        if (std.mem.endsWith(u8, public.items, "ENDPUB\n")) {
            got_public = true;
            break;
        }
    }
    try std.testing.expect(got_public);
    const pem = public.items[0 .. public.items.len - "ENDPUB\n".len];
    const raw = try tls.encryptRsa2048(a, pem, "synthetic-password");
    defer {
        std.crypto.secureZero(u8, raw);
        a.free(raw);
    }
    try std.testing.expectEqual(@as(usize, 256), raw.len);
    const encoded = try tls.encryptPassword(a, pem, "synthetic-password");
    defer {
        std.crypto.secureZero(u8, encoded);
        a.free(encoded);
    }
    try std.testing.expectEqual(@as(usize, 344), encoded.len);
    try writeTlsSmall(&client, fd, raw);
    try writeTlsSmall(&client, fd, encoded);
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(a);
    for (0..200) |_| {
        switch (try client.read(&small)) {
            .bytes => |count| try response.appendSlice(a, small[0..count]),
            .progress => |state| switch (state) {
                .want_read, .want_write => try pollTls(fd, state),
                else => return error.UnexpectedTlsState,
            },
        }
        if (response.items.len >= "fixture-response".len) break;
    }
    try std.testing.expectEqualStrings("fixture-response", response.items);
    for (0..100) |_| {
        const state = try client.closeNotifyStep();
        if (state == .ready or state == .closed) break;
        try pollTls(fd, state);
    }
    const term = try child.wait(std.testing.io);
    try std.testing.expect(term.success());
}

test "BMC TLS cancel trust rejection and cleanup keep the OwnedStream fd borrowed" {
    var pair: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &pair) != 0) return error.SocketPairFailed;
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);
    var client = try tls.Client.init(pair[0], "bmc.fixture.test");
    try std.testing.expectError(error.PeerChainUnavailable, client.peerChain(a));
    try std.testing.expectError(error.InvalidTlsState, client.authorizeTrust(true));
    client.cancel();
    try std.testing.expectError(error.Cancelled, client.handshakeStep());
    try std.testing.expectError(error.Cancelled, client.write("synthetic-password"));
    try std.testing.expectEqual(@as(c_int, 0), client.lastNativeError());
    client.deinit();
    try std.testing.expectEqual(@as(isize, 1), std.c.send(pair[0], "x", 1, 0));
    var byte: u8 = 0;
    try std.testing.expectEqual(@as(isize, 1), std.c.recv(pair[1], &byte, 1, 0));
    try std.testing.expectEqual(@as(u8, 'x'), byte);
}
