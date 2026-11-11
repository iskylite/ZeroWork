//! Public bootstrap fixtures use ephemeral loopback TLS only. No real BMC,
//! certificate, pin, password, token or remote SPA is stored by these tests.
const std = @import("std");
const native = @import("plugins/bmc_ikvm/native_driver.zig");
const provider = @import("plugins/bmc_ikvm/probe.zig");
const console = @import("plugins/bmc_ikvm/controller.zig");
const profile = @import("plugins/bmc_ikvm/protocol/profile.zig");
const auth = @import("plugins/bmc_ikvm/protocol/auth.zig");
const model = @import("plugins/bmc_ikvm/model.zig");
const route = @import("plugins/bmc_ikvm/route.zig");
const svc = @import("plugins/bmc_ikvm/services.zig");
const probes = @import("host/probe_contract.zig");
const contexts = @import("host/host_context.zig");
const trust = @import("host/tls_trust.zig");
const secrets = @import("host/secret_lease.zig");
const ssh = @import("proto/ssh/session.zig");
const budgets = @import("host/frame_budget.zig");
const ledger = @import("plugins/bmc_ikvm/management_journal.zig");
const a = std.testing.allocator;
const owner: svc.identity.SessionHandle = .{ .session_id = @fromBackingInt(2911), .generation = 7 };
const operation: svc.OperationKey = .{ .owner = .{ .session = owner }, .operation_id = 181, .attempt_id = 2 };
const parent: svc.OperationKey = .{ .owner = .app, .operation_id = 180 };
const old_reference = "zw1_0000000000000000000000000000000000000000000000000000000000000000";

const fixture =
    \\import base64,gzip,json,os,pathlib,socket,ssl,subprocess,sys,tempfile,time
    \\with tempfile.TemporaryDirectory(prefix='zerowork-bmc-bootstrap-') as directory:
    \\ d=pathlib.Path(directory);mode=sys.argv[2]
    \\ (d/'cert.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=127.0.0.1\n[ext]\nsubjectAltName=IP:127.0.0.1\n')
    \\ subprocess.run(['/usr/bin/openssl','req','-new','-x509','-newkey','rsa:2048','-nodes','-keyout',str(d/'key.pem'),'-out',str(d/'cert.pem'),'-days','1','-config',str(d/'cert.cnf')],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    \\ listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(2);listener.settimeout(10)
    \\ port=listener.getsockname()[1];control=socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=10);control.sendall(str(port).encode()+b'\n')
    \\ context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(d/'cert.pem',d/'key.pem')
    \\ paths=[];posts=0;logged_out=False;token=os.urandom(16).hex()
    \\ zero=mode in ('unknown','unknown-firmware','missing','no-firmware','untrusted') or mode.startswith('asset-')
    \\ try:
    \\  raw,_=listener.accept()
    \\  with context.wrap_socket(raw,server_side=True) as s:
    \\   s.settimeout(10);buffer=b''
    \\   def response(status,body=None,headers=None,binary=False):
    \\    b=body if binary else (json.dumps(body).encode() if body is not None else b'')
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
    \\    assert not any(k.startswith('sec-websocket') or k in ('upgrade','authkey','authorization') for k in headers)
    \\    length=int(headers.get('content-length','0'))
    \\    while len(buffer)<length: buffer+=s.recv(16384)
    \\    body,buffer=buffer[:length],buffer[length:];paths.append((method,path))
    \\    assert '/Oem/' not in path and path!='/kvm/0'
    \\    if method=='GET': assert not body
    \\    elif method=='POST': assert path=='/redfish/v1/SessionService/Sessions';posts+=1
    \\    elif method=='DELETE': assert path=='/redfish/v1/SessionService/Sessions/own-web' and not body
    \\    else: raise AssertionError('write or input request')
    \\    if path=='/redfish/v1/' and method=='GET':
    \\     public={'Copyright':{'EN':'Zhongke Sugon Information Industry Co., Ltd., Limited Copyright 2003-2025, All rights reserved'},'ProductName':'SuperPod','Platform':'Hygon','BMCChipModel':'AST2600-A3'}
    \\     root={'Manufacturer':'N/A','RedfishVersion':'1.17.0','Oem':{'Public':public},'Systems':{'@odata.id':'/redfish/v1/Systems'},'Managers':{'@odata.id':'/redfish/v1/Managers'},'SessionService':{'@odata.id':'/redfish/v1/SessionService'}}
    \\     if mode not in ('no-firmware',) and not mode.startswith(('asset-','pending-')): root['FirmwareVersion']='1.81' if mode=='unknown-firmware' else '1.80'
    \\     if mode=='unknown': public['Copyright']['EN']='Other manufacturer'
    \\     if mode=='missing': del public['ProductName']
    \\     if mode.startswith('asset-'): public['RedfishVersion']='1.17.2.0.3.8.0.21'
    \\     response(200,root)
    \\    elif path=='/js/app.0bc71eb0.js' and method=='GET':
    \\     assert mode.startswith('asset-') and headers.get('accept-encoding')=='gzip' and 'x-auth-token' not in headers
    \\     asset=b'/* ephemeral loopback asset */'*3000
    \\     if mode=='asset-large-gzip': asset=b''.join(os.urandom(1024)+b'/* ephemeral loopback only */'*144 for _ in range(2300))
    \\     if mode=='asset-bomb': asset=b'x'*(16*1024*1024+1)
    \\     encoded=gzip.compress(asset,mtime=0)
    \\     if mode=='asset-truncated': encoded=encoded[:-3]
    \\     if mode=='asset-trailing': encoded+=b'extra'
    \\     if mode in ('asset-slow-plain','asset-slow-gzip'):
    \\      b=asset if mode=='asset-slow-plain' else encoded
    \\      h=('HTTP/1.1 200 OK\r\nContent-Length: '+str(len(b))+'\r\n').encode()
    \\      if mode=='asset-slow-gzip': h+=b'Content-Encoding: gzip\r\n'
    \\      s.sendall(h+b'\r\n')
    \\      parts=[b[:len(b)//3],b[len(b)//3:2*len(b)//3],b[2*len(b)//3:]]
    \\      for i,part in enumerate(parts):
    \\       if i: time.sleep(8)
    \\       s.sendall(part)
    \\     elif mode=='asset-plain': response(200,asset,{},True)
    \\     else: response(200,encoded,{'Content-Encoding':'gzip'},True)
    \\    elif path=='/redfish/v1/SessionService' and method=='GET':
    \\     assert not zero
    \\     response(401) if mode=='prelogin401' and not posts else response(200,{'Sessions':{'@odata.id':'/redfish/v1/SessionService/Sessions'}})
    \\    elif method=='POST':
    \\     assert not zero and posts==1 and 'x-auth-token' not in headers
    \\     value=json.loads(body);assert sorted(value)==['Password','UserName'] and value['UserName']=='fixture'
    \\     assert len(base64.b64decode(value['Password'],validate=True))==256
    \\     response(201,{'Id':'own-web'},{'X-Auth-Token':token,'Location':'/redfish/v1/SessionService/Sessions/own-web'})
    \\    else:
    \\     assert headers.get('x-auth-token')==token
    \\     if method=='DELETE': logged_out=True;response(204);break
    \\     elif path=='/redfish/v1/Systems': response(200,{'Members':[{'@odata.id':'/redfish/v1/Systems/one'}]})
    \\     elif path=='/redfish/v1/Managers': response(200,{'Members':[{'@odata.id':'/redfish/v1/Managers/one'}]})
    \\     elif path=='/redfish/v1/Systems/one': response(200,{'Id':'one','UUID':'bootstrap-fixture','PowerState':'On','Links':{'ManagedBy':[{'@odata.id':'/redfish/v1/Managers/one'}]}})
    \\     elif path=='/redfish/v1/Managers/one':
    \\      manager={'Id':'one','FirmwareVersion':'1.81' if mode=='pending-mismatch' else '1.80','Links':{'ManagerForServers':[{'@odata.id':'/redfish/v1/Systems/one'}]}}
    \\      if mode=='pending-missing': del manager['FirmwareVersion']
    \\      response(200,manager)
    \\     else: raise AssertionError('unexpected discovery route '+path)
    \\ except (EOFError,ssl.SSLEOFError,ssl.SSLError,ConnectionResetError,BrokenPipeError):
    \\  assert zero,(mode,paths)
    \\ if zero:
    \\  assert posts==0 and not logged_out
    \\  if mode=='untrusted': assert paths==[]
    \\  elif mode.startswith('asset-'): assert paths==[('GET','/redfish/v1/'),('GET','/js/app.0bc71eb0.js')]
    \\  else: assert paths==[('GET','/redfish/v1/')]
    \\ else: assert posts==1 and logged_out
    \\ listener.settimeout(.05)
    \\ try: listener.accept();raise AssertionError('probe opened a second/video TCP stream')
    \\ except socket.timeout: pass
    \\ listener.close();control.close()
;

const Fixture = struct {
    child: std.process.Child,
    port: u16,
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
        var bytes: [8]u8 = undefined;
        var used: usize = 0;
        while (used == 0 or bytes[used - 1] != '\n') {
            var fds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (used == bytes.len or std.c.poll(&fds, 1, 10000) <= 0) return error.FixtureTimeout;
            const count = std.c.read(fd, bytes[used..].ptr, bytes.len - used);
            if (count <= 0) return error.FixtureClosed;
            used += @intCast(count);
        }
        return .{ .child = child, .port = try std.fmt.parseInt(u16, bytes[0 .. used - 1], 10), .control = fd };
    }
    fn deinit(self: *Fixture) void {
        if (self.child.id != null) self.child.kill(std.testing.io);
        _ = std.c.close(self.control);
    }
};

const Replies = struct {
    creator: std.Thread.Id,
    prompts: usize = 0,
    password_prompts: usize = 0,
    password: [32]u8 = undefined,
    fn reply(raw: *anyopaque, challenge: trust.Challenge, _: *const std.atomic.Value(bool)) !trust.TrustChoice {
        const self: *Replies = @ptrCast(@alignCast(raw));
        try std.testing.expect(std.Thread.getCurrentId() != self.creator);
        try std.testing.expect(challenge.owner.eql(owner) and challenge.operation.eql(operation));
        self.prompts += 1;
        return .once;
    }
    fn passwordReply(raw: *anyopaque, actual_owner: svc.identity.SessionHandle, actual_operation: svc.OperationKey, _: *const std.atomic.Value(bool), allocator: std.mem.Allocator) !auth.Secret {
        const self: *Replies = @ptrCast(@alignCast(raw));
        try std.testing.expect(std.Thread.getCurrentId() != self.creator);
        try std.testing.expect(actual_owner.eql(owner) and actual_operation.eql(operation));
        self.password_prompts += 1;
        return auth.Secret.init(allocator, &self.password);
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
fn pause() void {
    var fds: [1]std.c.pollfd = undefined;
    _ = std.c.poll(&fds, 0, 2);
}
fn request(context: probes.ProbeContext, bytes: []const u8) probes.ProbeRequest {
    return .{ .token = .{ .handle = context.owner, .operation = context.operation, .parent_editor_operation = parent, .draft_revision = 5 }, .handle = context.owner, .operation = context.operation, .parent_editor_operation = parent, .draft_revision = 5, .envelope = .{ .protocol_id = model.protocol_id, .name = "BMC bootstrap fixture", .payload = bytes }, .restricted_context = context };
}
fn drain(factory: probes.ProbeFactory) !probes.ProbeUpdate {
    for (0..10000) |_| {
        if (try factory.poll(factory.context, operation)) |update| switch (update) {
            .result => |result| if (result.cleanup == .released) return update,
            else => {},
        };
        pause();
    }
    return error.ProbeTimeout;
}
fn expectReadableFailure(mode: []const u8, err: anyerror, message: []const u8, observed_ms: u64) !void {
    // These expectations describe the fixture's real failing operation. Keep
    // them independent of the production label helper so a wrong phase/reason
    // does not pass just because the final message remains nonempty.
    const phase = if (std.mem.eql(u8, mode, "untrusted")) "TLS 握手" else if (std.mem.startsWith(u8, mode, "asset-")) "验证公开脚本摘要" else "读取公开设备身份";
    const reason = switch (err) {
        error.UnsupportedProfile => "当前版本不支持此设备或固件，请确认设备型号和固件版本。",
        error.UnsupportedProfileIdentityUnavailable => "目标未返回可验证的设备身份，请确认地址指向 BMC 管理界面。",
        error.UnsupportedProfileFirmwareUnavailable => "目标未返回可验证的固件信息。",
        error.TrustReplyUnavailable => "本次测试无法确认目标证书。请检查证书信任设置后重试。",
        error.UnsupportedProfilePublicEvidence => "无法取得可验证的公开设备信息，设备兼容性尚未确认。",
        error.InvalidPublicMaterialGzip => "设备返回的脚本压缩数据无效，请检查设备服务后重试。",
        error.BodyTooLarge => "设备返回的脚本超过大小上限，无法验证。",
        else => return error.UnexpectedProbeFailure,
    };
    var prefix_buffer: [256]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buffer, "{s}失败 · {s} · 总计 ", .{ phase, reason });
    try std.testing.expectEqualStrings(prefix, message[0..@min(prefix.len, message.len)]);
    const suffix = " 秒";
    try std.testing.expect(std.mem.endsWith(u8, message, suffix));
    try std.testing.expect(message.len > prefix.len + suffix.len);
    const seconds = message[prefix.len .. message.len - suffix.len];
    for (seconds) |digit| try std.testing.expect(std.ascii.isDigit(digit));
    const reported_seconds = try std.fmt.parseInt(u64, seconds, 10);
    // The tracker starts inside begin and ends before the released result is
    // observed. Scheduling/poll delay may enlarge this outer measurement.
    try std.testing.expect(reported_seconds <= observed_ms / 1000);
}

fn autoProbe(mode: []const u8, expected_error: ?anyerror, default_override: bool) !void {
    var server = try Fixture.start(mode);
    defer server.deinit();
    var library: ssh.Library = .{ .active = false };
    var cancel: std.atomic.Value(bool) = .init(false);
    var trust_store = trust.Store.init(a, .{ .verify = Replies.verify }, null);
    defer trust_store.deinit();
    var secret_store = secrets.Store.init(a);
    defer secret_store.deinit();
    var replies: Replies = .{ .creator = std.Thread.getCurrentId() };
    std.c.arc4random_buf(&replies.password, replies.password.len);
    defer std.crypto.secureZero(u8, &replies.password);
    if (default_override) try secret_store.authorizeDefault(owner, operation, &replies.password);
    const untrusted = std.mem.eql(u8, mode, "untrusted");
    const p = try provider.Provider.init(a, .{ .callbacks = if (untrusted) null else replies.callbacks() });
    defer p.deinit() catch unreachable;
    try std.testing.expect(p.selected == null);
    const bytes = try std.json.Stringify.valueAlloc(a, model.Payload{ .endpoint = .{ .host = "127.0.0.1", .https_port = server.port }, .username = "fixture", .credential_ref = if (default_override) old_reference else null }, .{});
    defer a.free(bytes);
    const context: probes.ProbeContext = .{ .owner = owner, .operation = operation, .cancel = &cancel, .transports = .{ .allocator = a, .library = &library }, .secrets = secret_store.facade(owner), .trust = .{ .tls = trust_store.facade(owner) } };
    const factory = p.factory();
    const started_ms = console.progress.nowMs();
    try factory.begin(factory.context, request(context, bytes));
    const result = (try drain(factory)).result;
    const elapsed_ms = console.progress.nowMs() -| started_ms;
    if (std.mem.startsWith(u8, mode, "asset-slow-")) try std.testing.expect(elapsed_ms >= 16000);
    try std.testing.expectEqual(if (expected_error == null) probes.Outcome.succeeded else probes.Outcome.failed, result.outcome);
    if (expected_error) |err| try expectReadableFailure(mode, err, result.safe_message, elapsed_ms);
    try std.testing.expectEqual(@as(usize, if (untrusted) 0 else 1), replies.prompts);
    try std.testing.expectEqual(@as(usize, if (expected_error != null or default_override) 0 else 1), replies.password_prompts);
    if (default_override) {
        var remaining = try context.secrets.?.acquireDefault(operation, &cancel);
        if (expected_error == null) {
            try std.testing.expect(remaining == .missing);
        } else switch (remaining) {
            .lease => |*lease| {
                defer lease.deinit();
                try std.testing.expectEqualSlices(u8, &replies.password, try lease.defaultBytes(owner, operation));
            },
            else => return error.UnrecognizedDeviceConsumedCredential,
        }
    }
    const term = try server.child.wait(std.testing.io);
    try std.testing.expect(term.success());
}

test "BMC bootstrap auto probe uses trusted actual identity with Manufacturer N/A and no video stream" {
    try autoProbe("success", null, false);
    try autoProbe("prelogin401", null, false);
}
test "BMC bootstrap unknown vendor and different firmware never try either login schema or consume credentials" {
    try autoProbe("unknown", error.UnsupportedProfile, true);
    try autoProbe("unknown-firmware", error.UnsupportedProfile, true);
}
test "BMC bootstrap missing public identity or firmware evidence fails before requesting a password" {
    try autoProbe("missing", error.UnsupportedProfileIdentityUnavailable, true);
    try autoProbe("no-firmware", error.UnsupportedProfileFirmwareUnavailable, true);
    try autoProbe("untrusted", error.TrustReplyUnavailable, true);
}
test "BMC bootstrap gzip and plain public assets require exact reviewed digest before credentials" {
    try autoProbe("asset-gzip", error.UnsupportedProfilePublicEvidence, true);
    try autoProbe("asset-plain", error.UnsupportedProfilePublicEvidence, true);
    try autoProbe("asset-truncated", error.InvalidPublicMaterialGzip, true);
    try autoProbe("asset-trailing", error.InvalidPublicMaterialGzip, true);
    try autoProbe("asset-bomb", error.BodyTooLarge, true);
}
test "BMC bootstrap large streamed gzip public asset completes framing and digest before rejecting unreviewed material" {
    // Match the live-shaped multi-megabyte encoded / eleven-megabyte decoded
    // body without retaining device JavaScript or weakening the digest gate.
    try autoProbe("asset-large-gzip", error.UnsupportedProfilePublicEvidence, true);
}
test "BMC bootstrap slow public assets keep downloading beyond fifteen seconds without consuming credentials" {
    try autoProbe("asset-slow-plain", error.UnsupportedProfilePublicEvidence, true);
    try autoProbe("asset-slow-gzip", error.UnsupportedProfilePublicEvidence, true);
}
test "BMC bootstrap operation default secret overrides an existing saved reference without prompting" {
    try autoProbe("success", null, true);
}

fn publicEvidenceProfile() !profile.Profile {
    return profile.selectPublicEvidence(.{ .trusted_channel = true, .copyright = "Zhongke Sugon Information Industry Co., Ltd.", .product = "SuperPod", .processor_vendor = "Hygon", .bmc_chip = "AST2600-A3", .firmware = "", .oem_namespace = "Public", .oem_redfish_version = "1.17.2.0.3.8.0.21" }, .{ .uri = profile.sugon_public_material_path, .sha256 = profile.sugon_public_material_sha256 });
}
const ProbeWorker = struct {
    backend: *native.NativeDriver,
    failure: ?anyerror = null,
    receipt: console.Cleanup = .not_started,
    fn run(self: *ProbeWorker) void {
        self.backend.beginProbe() catch |err| {
            self.failure = err;
        };
        self.receipt = self.backend.cleanupProbe();
    }
};
fn confirmFirmware(mode: []const u8, expected_error: ?anyerror) !void {
    var server = try Fixture.start(mode);
    defer server.deinit();
    var library: ssh.Library = .{ .active = false };
    var cancel: std.atomic.Value(bool) = .init(false);
    var trust_store = trust.Store.init(a, .{ .verify = Replies.verify }, null);
    defer trust_store.deinit();
    var replies: Replies = .{ .creator = std.Thread.getCurrentId() };
    std.c.arc4random_buf(&replies.password, replies.password.len);
    defer std.crypto.secureZero(u8, &replies.password);
    const value: model.Payload = .{ .endpoint = .{ .host = "127.0.0.1", .https_port = server.port }, .username = "fixture" };
    var plan = try route.Plan.init(a, owner, null, &.{}, .{ .host = value.endpoint.host, .port = value.endpoint.https_port });
    defer plan.deinit();
    const context: probes.ProbeContext = .{ .owner = owner, .operation = operation, .cancel = &cancel, .transports = .{ .allocator = a, .library = &library }, .trust = .{ .tls = trust_store.facade(owner) } };
    const backend = try native.NativeDriver.prepareProbe(a, context, value, &plan, &cancel, .{ .selected = try publicEvidenceProfile(), .callbacks = .{ .context = &replies, .trust_reply = Replies.reply, .password_reply = Replies.passwordReply } });
    defer backend.deinit() catch unreachable;
    // Public-evidence profiles carry their confirmation obligation even when
    // passed explicitly. The actual remote script is not a test fixture.
    try std.testing.expect(backend.firmware_pending_verification);
    var worker: ProbeWorker = .{ .backend = backend };
    const thread = try std.Thread.spawn(.{}, ProbeWorker.run, .{&worker});
    thread.join();
    try std.testing.expectEqual(expected_error, worker.failure);
    try std.testing.expectEqual(console.Cleanup.released, worker.receipt);
    try std.testing.expectEqual(expected_error == null, backend.diagnostics.firmware_observed);
    try std.testing.expectEqual(native.RemoteRelease.confirmed, backend.diagnostics.web_logout);
    try std.testing.expectEqual(native.RemoteRelease.not_created, backend.diagnostics.kvm_logout);
    try std.testing.expect(!backend.diagnostics.video_upgraded);
    const term = try server.child.wait(std.testing.io);
    try std.testing.expect(term.success());
}
test "BMC bootstrap public evidence requires actual post-WEB firmware and logs out before OEM on mismatch" {
    try confirmFirmware("pending-success", null);
    try confirmFirmware("pending-mismatch", error.UnsupportedProfileFirmwareMismatch);
    try confirmFirmware("pending-missing", error.UnsupportedProfileFirmwareUnavailable);
}

test "BMC bootstrap public asset evidence is distinct from an observed firmware version and bound to reviewed path" {
    const bytes =
        \\{"Manufacturer":"N/A","RedfishVersion":"1.17.0","Oem":{"Public":{"Copyright":{"EN":"Zhongke Sugon Information Industry Co., Ltd., Limited Copyright 2003-2025, All rights reserved"},"ProductName":"SuperPod","Platform":"Hygon","BMCChipModel":"AST2600-A3","RedfishVersion":"1.17.2.0.3.8.0.21"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    defer parsed.deinit();
    const observed = try profile.publicIdentityFromRoot(true, parsed.value);
    try std.testing.expectEqualStrings("", observed.firmware);
    try std.testing.expectError(error.UnsupportedProfileFirmwareUnavailable, profile.selectPublic(observed));
    try std.testing.expectError(error.UntrustedProfileInput, profile.publicIdentityFromRoot(false, parsed.value));
    const selected = try profile.selectPublicEvidence(observed, .{ .uri = profile.sugon_public_material_path, .sha256 = profile.sugon_public_material_sha256 });
    try selected.validateForProduction();
    try std.testing.expect(selected.identity_source == .reviewed_public_material);
    try std.testing.expectError(error.UnsupportedProfilePublicEvidence, profile.selectPublicEvidence(observed, .{ .uri = "/app.0bc71eb0.js", .sha256 = profile.sugon_public_material_sha256 }));
    try std.testing.expectError(error.UnsupportedProfilePublicEvidence, profile.selectPublicEvidence(observed, .{ .uri = profile.sugon_public_material_path, .sha256 = @splat(0) }));
    const reviewed = try std.json.parseFromSlice(std.json.Value, a, profile.sugon_public_fixture, .{});
    defer reviewed.deinit();
    const material = reviewed.value.object.get("public_material").?.object;
    try std.testing.expectEqualStrings(material.get("source_resource").?.string, profile.sugon_public_material_path);
    const digest_hex = std.fmt.bytesToHex(profile.sugon_public_material_sha256, .lower);
    try std.testing.expectEqualStrings(material.get("source_sha256").?.string, &digest_hex);
}

test "BMC bootstrap startPrepared defers actual unknown-device failure to worker and releases native resources" {
    var server = try Fixture.start("unknown");
    defer server.deinit();
    var library: ssh.Library = .{ .active = false };
    var trust_store = trust.Store.init(a, .{ .verify = Replies.verify }, null);
    defer trust_store.deinit();
    var replies: Replies = .{ .creator = std.Thread.getCurrentId() };
    var budget = budgets.Budget.init(128 * 1024 * 1024);
    defer budget.deinit() catch unreachable;
    var memory: ledger.MemoryBackend = .{ .allocator = a };
    defer memory.deinit();
    var journal = try ledger.Journal.init(a, memory.backend());
    defer journal.deinit();
    const value: model.Payload = .{ .endpoint = .{ .host = "127.0.0.1", .https_port = server.port }, .username = "fixture" };
    const controller = try console.Controller.create(a, owner, operation, value, null, &budget, &journal, null);
    defer controller.deinit() catch unreachable;
    const context: contexts.HostContext = .{ .owner = owner, .operation = operation, .target = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) }, .transports = .{ .allocator = a, .library = &library }, .trust = .{ .tls = trust_store.facade(owner) } };
    const backend = try native.NativeDriver.prepare(a, context, value, &controller.plan, &controller.cancel_requested, .{ .callbacks = .{ .context = &replies, .trust_reply = Replies.reply, .password_reply = Replies.passwordReply } });
    defer backend.deinit() catch unreachable;
    try std.testing.expect(!backend.pair.transport.started and !backend.selection_ready);
    try std.testing.expectError(error.NativeIoOnConfigurationThread, backend.driver().begin(backend, &value, &controller.plan, operation, &controller.cancel_requested));
    try controller.startPrepared(backend.driver());
    for (0..10000) |_| {
        if (controller.poll().worker_exited) break;
        pause();
    }
    const snapshot = controller.poll();
    try std.testing.expect(snapshot.worker_exited);
    try std.testing.expectEqual(error.UnsupportedProfile, snapshot.failure.?);
    try std.testing.expectEqual(console.Cleanup.released, snapshot.cleanup);
    try std.testing.expectEqual(@as(usize, 0), replies.password_prompts);
    try std.testing.expect(!backend.selection_ready and !backend.diagnostics.video_upgraded);
    const term = try server.child.wait(std.testing.io);
    try std.testing.expect(term.success());
}
