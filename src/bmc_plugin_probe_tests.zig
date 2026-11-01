const std = @import("std");
const probes = @import("host/probe_contract.zig");
const provider = @import("plugins/bmc_ikvm/probe.zig");
const native = @import("plugins/bmc_ikvm/native_driver.zig");
const profile = @import("plugins/bmc_ikvm/protocol/profile.zig");
const auth = @import("plugins/bmc_ikvm/protocol/auth.zig");
const model = @import("plugins/bmc_ikvm/model.zig");
const route = @import("plugins/bmc_ikvm/route.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const trust = @import("host/tls_trust.zig");
const transport = @import("host/transport_factory.zig");
const ssh = @import("proto/ssh/session.zig");
const a = std.testing.allocator;
const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(2902), .generation = 9 };
const operation: svc.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 180, .attempt_id = 3 };
const parent: svc.OperationKey = .{ .owner = .app, .operation_id = 179 };
const payload: model.Payload = .{ .endpoint = .{ .host = "127.0.0.1", .https_port = 1 }, .username = "fixture" };

// Only ephemeral loopback sockets, RSA key/certificate and one-run passwords.
// One TLS connection is allowed; any OEM/KVM/WS/input/write request fails.
const fixture =
    \\import base64,json,os,pathlib,socket,ssl,subprocess,sys,tempfile,time
    \\with tempfile.TemporaryDirectory(prefix='zerowork-bmc-probe-') as directory:
    \\ d=pathlib.Path(directory)
    \\ (d/'cert.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=127.0.0.1\n[ext]\nsubjectAltName=IP:127.0.0.1\n')
    \\ subprocess.run(['/usr/bin/openssl','req','-new','-x509','-newkey','rsa:2048','-nodes','-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem'),'-days','1','-config',str(d/'cert.cnf')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    \\ public=subprocess.run(['/usr/bin/openssl','pkey','-in',str(d/'key.pem'),'-pubout'],capture_output=True,check=True).stdout
    \\ listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(2);listener.settimeout(10)
    \\ port=listener.getsockname()[1];mode=sys.argv[2]
    \\ control=socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=10)
    \\ control.sendall(str(port).encode()+b'\n'+public+b'ENDPUB\n')
    \\ expected=b''
    \\ while len(expected)<32: expected+=control.recv(32-len(expected))
    \\ context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(d/'cert.pem',d/'key.pem')
    \\ paths=[];logged_out=False;token=os.urandom(16).hex()
    \\ try:
    \\  raw,_=listener.accept()
    \\  with context.wrap_socket(raw,server_side=True) as s:
    \\   s.settimeout(10);buffer=b''
    \\   def response(status,body=None,headers=None):
    \\    b=json.dumps(body).encode() if body is not None else b''
    \\    h=('HTTP/1.1 '+str(status)+' OK\r\nContent-Length: '+str(len(b))+'\r\n').encode()
    \\    for k,v in (headers or {}).items(): h+=(k+': '+v+'\r\n').encode()
    \\    s.sendall(h+b'\r\n'+b)
    \\   while True:
    \\    while b'\r\n\r\n' not in buffer:
    \\     b=s.recv(16384)
    \\     if not b: raise EOFError()
    \\     buffer+=b
    \\    head,buffer=buffer.split(b'\r\n\r\n',1);lines=head.decode().split('\r\n');method,path,_=lines[0].split(' ')
    \\    headers={k.lower():v.strip() for k,v in (line.split(':',1) for line in lines[1:])}
    \\    assert headers['host']=='127.0.0.1:'+str(port)
    \\    assert sum(line.lower().startswith('from:') for line in lines[1:])==1 and headers['from']=='WebUI'
    \\    assert sum(line.lower().startswith('x-requested-with:') for line in lines[1:])==1 and headers['x-requested-with']=='XMLHttpRequest'
    \\    assert not any(k.startswith('sec-websocket') or k in ('upgrade','authkey') for k in headers)
    \\    length=int(headers.get('content-length','0'))
    \\    while len(buffer)<length: buffer+=s.recv(16384)
    \\    body,buffer=buffer[:length],buffer[length:];paths.append((method,path))
    \\    assert '/Oem/' not in path and path!='/kvm/0'
    \\    if method=='GET': assert not body
    \\    elif method=='POST': assert path=='/redfish/v1/SessionService/Sessions'
    \\    elif method=='DELETE': assert path=='/redfish/v1/SessionService/Sessions/own-web' and not body
    \\    else: raise AssertionError('management write/input method')
    \\    if path=='/redfish/v1/' and method=='GET':
    \\     service='/redfish/v1/OtherSessionService' if mode=='wrong-parent' else '/redfish/v1/SessionService'
    \\     response(200,{'Systems':{'@odata.id':'/redfish/v1/Systems'},'Managers':{'@odata.id':'/redfish/v1/Managers'},'SessionService':{'@odata.id':service}})
    \\    elif path in ('/redfish/v1/SessionService','/redfish/v1/OtherSessionService') and method=='GET':
    \\     if mode in ('prelogin401','wrong-parent'): response(401)
    \\     else: response(200,{'Sessions':{'@odata.id':'/redfish/v1/SessionService/Sessions'}})
    \\    elif path=='/redfish/v1/SessionService/Sessions' and method=='POST':
    \\     assert 'x-auth-token' not in headers
    \\     request=json.loads(body);assert request['UserName']=='fixture'
    \\     ciphertext=base64.b64decode(request['Password'],validate=True);assert len(ciphertext)==256
    \\     decrypted=subprocess.run(['/usr/bin/openssl','pkeyutl','-decrypt','-inkey',str(d/'key.pem'),'-pkeyopt','rsa_padding_mode:pkcs1'],input=ciphertext,capture_output=True,check=True)
    \\     assert decrypted.stdout==expected
    \\     response(201,{'Id':'own-web'},{'X-Auth-Token':token,'Location':'/redfish/v1/SessionService/Sessions/own-web'})
    \\    else:
    \\     assert headers.get('x-auth-token')==token
    \\     if method=='DELETE':
    \\      logged_out=True
    \\      response(202,{'TaskState':'Running'}) if mode=='logout-unknown' else response(200,{'error':{'code':'Base.1.19.Success','@Message.ExtendedInfo':[{'MessageId':'Base.1.19.Success','Severity':'OK'}]}})
    \\      break
    \\     elif path=='/redfish/v1/Systems':
    \\      if mode=='cancel': control.sendall(b'D');time.sleep(.2)
    \\      response(200,{'Members':[{'@odata.id':'/redfish/v1/Systems/one'}]})
    \\     elif path=='/redfish/v1/Managers': response(200,{'Members':[{'@odata.id':'/redfish/v1/Managers/one'}]})
    \\     elif path=='/redfish/v1/Systems/one': response(200,{'Id':'one','UUID':'probe-system','PowerState':'On','Links':{'ManagedBy':[{'@odata.id':'/redfish/v1/Managers/one'}]}})
    \\     elif path=='/redfish/v1/Managers/one': response(200,{'Id':'one','Links':{'ManagerForServers':[{'@odata.id':'/redfish/v1/Systems/one'}]}})
    \\     else: raise AssertionError('unexpected discovery route '+path)
    \\ except (EOFError,ssl.SSLEOFError,ssl.SSLError,ConnectionResetError,BrokenPipeError):
    \\  assert mode in ('cancel','untrusted','wrong-parent'),(mode,paths)
    \\ if mode=='untrusted': assert paths==[]
    \\ elif mode=='wrong-parent': assert all(method=='GET' for method,_ in paths)
    \\ else:
    \\  assert ('POST','/redfish/v1/SessionService/Sessions') in paths
    \\  assert logged_out or mode=='cancel'
    \\ listener.settimeout(.1)
    \\ try: listener.accept();raise AssertionError('second TCP/video stream created')
    \\ except socket.timeout: pass
    \\ listener.close();control.close()
;

const Fixture = struct {
    child: std.process.Child,
    port: u16,
    pem: []u8,
    password: [32]u8,
    control: c_int,
    fn start(mode: []const u8) !Fixture {
        const listener = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (listener < 0) return error.SocketFailed;
        defer _ = std.c.close(listener);
        var address: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(listener, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0 or std.c.listen(listener, 1) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(@TypeOf(address));
        if (std.c.getsockname(listener, @ptrCast(&address), &len) != 0) return error.AddressFailed;
        const port = try std.fmt.allocPrint(a, "{d}", .{std.mem.bigToNative(u16, address.port)});
        defer a.free(port);
        var child = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/usr/bin/python3", "-c", fixture, port, mode } });
        errdefer child.kill(std.testing.io);
        var pending = [_]std.c.pollfd{.{ .fd = listener, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&pending, 1, 10000) <= 0) return error.FixtureTimeout;
        const fd = std.c.accept(listener, null, null);
        if (fd < 0) return error.AcceptFailed;
        errdefer _ = std.c.close(fd);
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(a);
        var bytes: [512]u8 = undefined;
        while (!std.mem.endsWith(u8, data.items, "ENDPUB\n")) {
            var fds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 10000) <= 0) return error.FixtureTimeout;
            const n = std.c.read(fd, &bytes, bytes.len);
            if (n <= 0) return error.FixtureClosed;
            try data.appendSlice(a, bytes[0..@intCast(n)]);
            if (data.items.len > 16384) return error.FixtureTooLarge;
        }
        const newline = std.mem.indexOfScalar(u8, data.items, '\n') orelse return error.FixtureProtocol;
        var password: [32]u8 = undefined;
        std.c.arc4random_buf(&password, password.len);
        if (std.c.write(fd, &password, password.len) != password.len) return error.FixtureClosed;
        return .{ .child = child, .port = try std.fmt.parseInt(u16, data.items[0..newline], 10), .pem = try a.dupe(u8, data.items[newline + 1 .. data.items.len - "ENDPUB\n".len]), .password = password, .control = fd };
    }
    fn deinit(self: *Fixture) void {
        if (self.child.id != null) self.child.kill(std.testing.io);
        _ = std.c.close(self.control);
        a.free(self.pem);
        std.crypto.secureZero(u8, &self.password);
    }
};

const Replies = struct {
    password: []const u8,
    prompts: usize = 0,
    password_prompts: usize = 0,
    hold: bool = false,
    reject: bool = false,
    entered: std.atomic.Value(bool) = .init(false),
    allow: std.atomic.Value(bool) = .init(false),
    fn reply(raw: *anyopaque, challenge: trust.Challenge, _: *const std.atomic.Value(bool)) !trust.TrustChoice {
        const self: *Replies = @ptrCast(@alignCast(raw));
        try std.testing.expect(challenge.owner.eql(owner));
        try std.testing.expect(challenge.operation.eql(operation));
        self.prompts += 1;
        self.entered.store(true, .release);
        while (self.hold and !self.allow.load(.acquire)) pause();
        return if (self.reject) .reject else .once;
    }
    fn passwordReply(raw: *anyopaque, actual_owner: svc.identity.SessionHandle, actual_operation: svc.OperationKey, _: *const std.atomic.Value(bool), allocator: std.mem.Allocator) !auth.Secret {
        const self: *Replies = @ptrCast(@alignCast(raw));
        try std.testing.expect(actual_owner.eql(owner));
        try std.testing.expect(actual_operation.eql(operation));
        self.password_prompts += 1;
        return auth.Secret.init(allocator, self.password);
    }
    fn verify(_: ?*anyopaque, authority: trust.Authority, chain: []const []const u8) !trust.VerificationResult {
        try std.testing.expectEqualStrings("127.0.0.1", authority.host);
        try std.testing.expect(chain.len == 1 and chain[0].len > 500);
        return .{ .failures = .{ .untrusted_issuer = true } };
    }
    fn callbacks(self: *Replies) provider.Callbacks {
        return .{ .context = self, .trust_reply = reply, .password_reply = passwordReply };
    }
};
fn identity() profile.Identity {
    return .{ .trusted_channel = true, .manufacturer = "Sugon", .product = "SuperPod", .processor_vendor = "Hygon", .bmc_chip = "AST2600-A3", .firmware = "1.80", .oem_namespace = "Public", .kvm_login_resource = profile.kvm_login_path, .oem_rfb = true };
}
fn selected(pem: []const u8) !profile.Profile {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pem, &digest, .{});
    return profile.syntheticForTest(identity(), .{ .firmware = "1.80", .identity_fixture_sha256 = @splat(1), .public_key_pem = pem, .public_key_sha256 = digest, .public_key_source = "ephemeral loopback-only fixture", .web_login_schema_verified = true, .kvm_login_schema_verified = true, .ws_subprotocol_echo_verified = true, .oem_handshake_verified = true, .web_logout = .own_session_location, .kvm_logout = .own_session_location });
}
fn request(context: probes.ProbeContext, bytes: []const u8) probes.ProbeRequest {
    return .{ .token = .{ .handle = context.owner, .operation = context.operation, .parent_editor_operation = parent, .draft_revision = 4 }, .handle = context.owner, .operation = context.operation, .parent_editor_operation = parent, .draft_revision = 4, .envelope = .{ .protocol_id = model.protocol_id, .name = "BMC probe fixture", .payload = bytes }, .restricted_context = context };
}
fn pause() void {
    var fds: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&fds, 0, 2);
}
fn drain(factory: probes.ProbeFactory, key: svc.OperationKey) !probes.ProbeUpdate {
    var remaining: usize = 5000;
    while (remaining != 0) : (remaining -= 1) {
        if (try factory.poll(factory.context, key)) |update| switch (update) {
            .result => |result| if (result.cleanup == .released) return update,
            else => {},
        };
        pause();
    }
    return error.ProbeTimeout;
}

fn loopback(mode: []const u8) !void {
    var server = try Fixture.start(mode);
    defer server.deinit();
    var library: ssh.Library = .{ .active = false };
    var cancel_source: std.atomic.Value(bool) = .init(false);
    var trust_store = trust.Store.init(a, .{ .verify = Replies.verify }, null);
    defer trust_store.deinit();
    var replies: Replies = .{ .password = &server.password };
    const untrusted = std.mem.eql(u8, mode, "untrusted");
    const p = try provider.Provider.init(a, .{ .selected = try selected(server.pem), .callbacks = if (untrusted) null else replies.callbacks() });
    defer p.deinit() catch unreachable;
    // Provider owns the evidence strings; callers may discard their sources.
    @memset(server.pem, 'x');
    const value: model.Payload = .{ .endpoint = .{ .host = "127.0.0.1", .https_port = server.port }, .username = "fixture" };
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    const context: probes.ProbeContext = .{ .owner = owner, .operation = operation, .cancel = &cancel_source, .transports = .{ .allocator = a, .library = &library }, .trust = .{ .tls = trust_store.facade(owner) } };
    const factory = p.factory();
    try factory.begin(factory.context, request(context, bytes));
    @memset(bytes, 'x');
    a.free(bytes);
    if (std.mem.eql(u8, mode, "cancel")) {
        var ready = [_]std.c.pollfd{.{ .fd = server.control, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&ready, 1, 10000) <= 0) return error.FixtureTimeout;
        var marker: [1]u8 = undefined;
        try std.testing.expectEqual(@as(isize, 1), std.c.read(server.control, &marker, 1));
        try std.testing.expectEqual(@as(u8, 'D'), marker[0]);
        cancel_source.store(true, .release);
        try std.testing.expectEqual(probes.CloseReceipt.awaiting, factory.cancel(factory.context, operation));
    }
    const result = (try drain(factory, operation)).result;
    const expected: probes.Outcome = if (untrusted or std.mem.eql(u8, mode, "wrong-parent")) .failed else if (std.mem.eql(u8, mode, "cancel")) .cancelled else .succeeded;
    try std.testing.expectEqual(expected, result.outcome);
    if (std.mem.eql(u8, mode, "logout-unknown") or std.mem.eql(u8, mode, "cancel")) try std.testing.expect(std.mem.indexOf(u8, result.safe_message, "注销未确认") != null);
    try std.testing.expectEqual(@as(usize, if (untrusted) 0 else 1), replies.prompts);
    try std.testing.expectEqual(@as(usize, if (untrusted or std.mem.eql(u8, mode, "wrong-parent")) 0 else 1), replies.password_prompts);
    const term = try server.child.wait(std.testing.io);
    try std.testing.expect(term.success());
}

test "BMC plugin probe owns a single TLS management stream and performs only WEB login read discovery own logout" {
    try loopback("success");
}
test "BMC plugin probe accepted profile handles protected prelogin SessionService using reviewed WEB collection" {
    try loopback("prelogin401");
    try loopback("wrong-parent");
}
test "BMC plugin probe preserves unknown remote logout while proving local release" {
    try loopback("logout-unknown");
}
test "BMC plugin probe cancellation suppresses late success and releases its own stream" {
    try loopback("cancel");
}
test "BMC plugin probe missing trust reply sends no HTTP or credentials" {
    try loopback("untrusted");
}

test "BMC plugin probe pending and unknown cleanup retain actual owner until a later native receipt" {
    var server = try Fixture.start("untrusted");
    defer server.deinit();
    var library: ssh.Library = .{ .active = false };
    var cancel_source: std.atomic.Value(bool) = .init(false);
    var trust_store = trust.Store.init(a, .{ .verify = Replies.verify }, null);
    defer trust_store.deinit();
    var replies: Replies = .{ .password = &server.password, .hold = true, .reject = true };
    const p = try provider.Provider.init(a, .{ .selected = try selected(server.pem), .callbacks = replies.callbacks() });
    defer p.deinit() catch unreachable;
    const bytes = try std.json.Stringify.valueAlloc(a, model.Payload{ .endpoint = .{ .host = "127.0.0.1", .https_port = server.port }, .username = "fixture" }, .{});
    defer a.free(bytes);
    const context: probes.ProbeContext = .{ .owner = owner, .operation = operation, .cancel = &cancel_source, .transports = .{ .allocator = a, .library = &library }, .trust = .{ .tls = trust_store.facade(owner) } };
    const factory = p.factory();
    try factory.begin(factory.context, request(context, bytes));
    var waits: usize = 5000;
    while (!replies.entered.load(.acquire) and waits != 0) : (waits -= 1) pause();
    try std.testing.expect(replies.entered.load(.acquire));
    const entry = p.entries[0].?;
    // Inject only a diagnostic release receipt while both protocol/native
    // cleanup are stopped at the trust reply. The real ledger is threadsafe.
    entry.backend.pair.transport.ledger = try ssh.ResourceLedger.init(operation, 1);
    const ledger = &entry.backend.pair.transport.ledger.?;
    try std.testing.expect(ledger.record(operation, 0, .transport, .owned));
    try std.testing.expect(ledger.record(operation, 0, .transport, .unknown));
    // A separate finished operation still owes its receipt to the host. A
    // pending provider deinit must preserve that delivery along with live IO.
    var second_cancel: std.atomic.Value(bool) = .init(false);
    const second_bytes = try std.json.Stringify.valueAlloc(a, payload, .{});
    defer a.free(second_bytes);
    var second_context = context;
    second_context.operation.operation_id += 1;
    second_context.cancel = &second_cancel;
    try factory.begin(factory.context, request(second_context, second_bytes));
    second_cancel.store(true, .release);
    waits = 5000;
    while (!p.entries[1].?.done.load(.acquire) and waits != 0) : (waits -= 1) pause();
    try std.testing.expect(p.entries[1].?.done.load(.acquire));
    _ = try factory.poll(factory.context, operation);
    try std.testing.expectEqual(probes.CloseReceipt.awaiting, factory.cancel(factory.context, operation));
    try std.testing.expectError(error.ProbeCleanupPending, p.deinit());
    try std.testing.expect(p.entries[1] != null);
    const second_result = (try factory.poll(factory.context, second_context.operation)).?.result;
    try std.testing.expectEqual(probes.CloseReceipt.released, second_result.cleanup);
    replies.allow.store(true, .release);
    waits = 5000;
    var unknown_seen = false;
    while (waits != 0) : (waits -= 1) {
        if (try factory.poll(factory.context, operation)) |update| switch (update) {
            .result => |result| if (result.cleanup == .unknown) {
                try std.testing.expectEqual(probes.Outcome.cancelled, result.outcome);
                unknown_seen = true;
                break;
            },
            else => {},
        };
        pause();
    }
    try std.testing.expect(unknown_seen);
    try std.testing.expectError(error.ProbeCleanupPending, p.deinit());
    try std.testing.expect(p.entries[0] != null and !entry.done.load(.acquire));
    try std.testing.expect(ledger.record(operation, 0, .transport, .released));
    const result = (try drain(factory, operation)).result;
    try std.testing.expectEqual(probes.Outcome.cancelled, result.outcome);
    try std.testing.expectEqual(probes.CloseReceipt.released, result.cleanup);
    const term = try server.child.wait(std.testing.io);
    try std.testing.expect(term.success());
}

const Reservations = struct {
    held: usize = 0,
    credentials_resolved: usize = 0,
    fn reserve(raw: *anyopaque) !void {
        const self: *Reservations = @ptrCast(@alignCast(raw));
        self.held += 1;
    }
    fn release(raw: *anyopaque) void {
        const self: *Reservations = @ptrCast(@alignCast(raw));
        self.held -= 1;
    }
    fn adopt(_: *anyopaque, _: *transport.OwnedTransport) void {
        unreachable;
    }
    fn resolve(raw: *anyopaque, actual_owner: svc.identity.ResourceOwner, _: svc.identity.AssetOwner, allocator: std.mem.Allocator) !ssh.Auth {
        const self: *Reservations = @ptrCast(@alignCast(raw));
        try std.testing.expect(actual_owner == .session and actual_owner.session.eql(owner));
        self.credentials_resolved += 1;
        return .{ .password = try allocator.dupeSentinel(u8, "temporary-owned-ssh-secret", 0) };
    }
    fn factory(self: *Reservations, library: *ssh.Library) transport.Factory {
        return .{ .allocator = a, .library = library, .failed_open_owner = .{ .context = self, .reserve = reserve, .release = release, .adopt = adopt }, .credentials = .{ .context = self, .resolve = resolve } };
    }
};

test "BMC plugin probe prepared cancel discard and spawn failure wipe auth and release reserved cleanup without IO" {
    const hosts = @import("config/hosts.zig");
    const resolver = @import("host/connection_config_resolver.zig");
    var registry = try hosts.Registry.parse(a, "");
    defer registry.deinit();
    const hop = try registry.add(.{ .name = "offline", .host = "offline.invalid", .user = "u", .auth_mode = .password });
    var library: ssh.Library = .{ .active = false };
    var reservations: Reservations = .{};
    var cancel_source: std.atomic.Value(bool) = .init(false);
    var source_factory = reservations.factory(&library);
    source_factory.cleanup_destination = .{ .host = payload.endpoint.host, .port = payload.endpoint.https_port };
    const context: probes.ProbeContext = .{ .owner = owner, .operation = operation, .cancel = &cancel_source, .connection_configs = resolver.Resolver.init(&registry), .transports = source_factory };
    var plan = try route.Plan.init(a, owner, context.connection_configs, &.{hop.id}, .{ .host = payload.endpoint.host, .port = payload.endpoint.https_port });
    defer plan.deinit();
    const selected_profile = try profile.select(identity());
    const backend = try native.NativeDriver.prepareProbe(a, context, payload, &plan, &cancel_source, .{ .selected = selected_profile });
    try std.testing.expectEqual(@as(usize, 1), reservations.held);
    try std.testing.expectEqual(@as(usize, 1), reservations.credentials_resolved);
    try std.testing.expect(backend.driver().management_io == null);
    try std.testing.expectEqual(@as(usize, 0), backend.pair.transport.cleanup_host_len);
    try std.testing.expectError(error.CleanupStreamForbidden, backend.pair.transport.openCleanupTcpStream());
    try std.testing.expectError(error.NativeIoOnConfigurationThread, backend.beginProbe());
    backend.pair.transport.started = true;
    try std.testing.expectError(error.NativeDriverAlreadyStarted, backend.discardPrepared());
    backend.pair.transport.started = false;
    cancel_source.store(true, .release);
    try backend.discardPrepared();
    try std.testing.expectEqual(@as(usize, 0), reservations.held);
    cancel_source.store(false, .release);
    const p = try provider.Provider.init(a, .{ .selected = selected_profile });
    defer p.deinit() catch unreachable;
    p.test_fail_spawn = true;
    const bytes = try std.json.Stringify.valueAlloc(a, model.Payload{ .endpoint = payload.endpoint, .username = payload.username, .access = .{ .ssh_route = .{ .hops = &.{.{ .asset_id = @backingInt(hop.id) }} } } }, .{});
    defer a.free(bytes);
    const factory = p.factory();
    try std.testing.expectError(error.ThreadQuotaExceeded, factory.begin(factory.context, request(context, bytes)));
    try std.testing.expectEqual(@as(usize, 0), reservations.held);
    try std.testing.expectEqual(@as(usize, 2), reservations.credentials_resolved);
    try std.testing.expect(p.entries[0] == null);
}

test "BMC plugin probe rejects stale owners before IO and reuses completed slots beyond 128 probes" {
    var library: ssh.Library = .{ .active = false };
    var cancel_source: std.atomic.Value(bool) = .init(false);
    const context: probes.ProbeContext = .{ .owner = owner, .operation = operation, .cancel = &cancel_source, .transports = .{ .allocator = a, .library = &library } };
    const bytes = try std.json.Stringify.valueAlloc(a, payload, .{});
    defer a.free(bytes);
    const p = try provider.Provider.init(a, .{ .selected = try profile.select(identity()) });
    defer p.deinit() catch unreachable;
    const factory = p.factory();
    var stale = request(context, bytes);
    stale.restricted_context.owner.generation += 1;
    try std.testing.expectError(error.StaleProbeContext, factory.begin(factory.context, stale));
    stale = request(context, bytes);
    stale.token.draft_revision += 1;
    try std.testing.expectError(error.StaleProbeRequest, factory.begin(factory.context, stale));
    for (0..140) |index| {
        var next = request(context, bytes);
        next.operation.operation_id += index;
        next.token.operation = next.operation;
        next.restricted_context.operation = next.operation;
        try factory.begin(factory.context, next);
        const receipt = factory.cancel(factory.context, next.operation);
        if (receipt != .released) {
            const result = (try drain(factory, next.operation)).result;
            try std.testing.expectEqual(probes.Outcome.cancelled, result.outcome);
        }
        try std.testing.expectError(error.StaleProbeOperation, factory.poll(factory.context, next.operation));
    }
}
