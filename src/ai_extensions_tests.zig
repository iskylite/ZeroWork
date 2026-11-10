const std = @import("std");
const a = std.testing.allocator;
const cfg = @import("config/config.zig");
const ext = cfg.ai_extensions;
const skills = @import("ai/local_skills.zig");
const mcp = @import("ai/mcp_client.zig");
test "v0.4 extensions configuration is owned roundtripped and composite merge preserves external edits" {
    var server = [_]ext.Server{.{ .id = "local", .name = "Local materials", .program = "/usr/bin/python3", .args = &.{"--version"} }};
    var value: cfg.Config = .{};
    value.ai.extensions.servers = &server;
    var snapshot = try @import("config/runtime_config.zig").Snapshot.init(a, value);
    defer snapshot.deinit();
    server[0].name = "mutated";
    try std.testing.expectEqualStrings("Local materials", snapshot.value.ai.extensions.servers[0].name);
    const buffer = try a.alloc(u8, 256 * 1024);
    defer a.free(buffer);
    const encoded = try snapshot.value.format(buffer);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try cfg.Config.parseWithAllocator(arena.allocator(), encoded);
    try std.testing.expectEqualStrings("Local materials", parsed.ai.extensions.servers[0].name);
    const schema = @import("config/settings_schema.zig");
    var dirty: schema.FieldSet = .empty;
    dirty.set(schema.extensions_index);
    var latest: cfg.Config = .{};
    latest.ui.font_size = 19;
    const merged = schema.merge(latest, snapshot.value, dirty);
    try std.testing.expectEqual(@as(u8, 19), merged.ui.font_size);
    try std.testing.expectEqual(@as(usize, 1), merged.ai.extensions.servers.len);
}
test "v0.4 extensions local import owns package and rejects escapes missing files and tampering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "source/references");
    const body = "---\nname: local-audit\ndescription: Check only supplied material\n---\nRead [reference](references/guide.txt). Never execute scripts.\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source/SKILL.md", .data = body });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source/references/guide.txt", .data = "safe reference" });
    const source = try tmp.dir.realPathFileAlloc(std.testing.io, "source", a);
    defer a.free(source);
    var imported = try skills.importLocal(a, std.testing.io, tmp.dir, source, null);
    defer imported.deinit();
    try tmp.dir.deleteTree(std.testing.io, "source");
    const read = try skills.read(a, std.testing.io, tmp.dir, imported.skill, "references/guide.txt");
    defer a.free(read);
    try std.testing.expectEqualStrings("safe reference", read);
    try std.testing.expectError(error.InvalidSkillPath, skills.read(a, std.testing.io, tmp.dir, imported.skill, "../config.toml"));
    const path = try std.fmt.allocPrint(a, "ai/skills/{s}/{s}/references/guide.txt", .{ imported.skill.id, imported.skill.revision });
    defer a.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "tampered" });
    try std.testing.expectError(error.SkillIntegrityFailure, skills.read(a, std.testing.io, tmp.dir, imported.skill, "references/guide.txt"));
}
test "v0.4 extensions stdio initializes pages tools validates inner schema and closes real process" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        \\import sys,json,os
        \\assert_environment = os.environ.get("PATH")=="/fixture-only/bin" and "HOME" not in os.environ and "OPENAI_API_KEY" not in os.environ
        \\assert assert_environment
        \\for line in sys.stdin:
        \\ r=json.loads(line); m=r.get('method'); i=r.get('id')
        \\ if i is None: continue
        \\ assert isinstance(r.get('params'),dict)
        \\ if m=='initialize': assert isinstance(r['params']['capabilities'],dict)
        \\ if m=='initialize': out={'protocolVersion':'2025-11-25','capabilities':{'tools':{}}}
        \\ elif m=='tools/list': out={'tools':[]} if r.get('params',{}).get('cursor')=='page-two' else {'tools':[{'name':'material','description':'fixture','inputSchema':{'type':'object','additionalProperties':False,'properties':{'text':{'type':'string','maxLength':64}},'required':['text']}}],'nextCursor':'page-two'}
        \\ elif m=='tools/call': out={'content':[{'type':'text','text':r['params']['arguments']['text'].upper()}]}
        \\ for _ in range(140): print(json.dumps({'jsonrpc':'2.0','method':'notifications/progress','params':{'progressToken':'fixture','progress':1}}),flush=True)
        \\ print(json.dumps({'jsonrpc':'2.0','id':i,'result':out}),flush=True)
    ;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "server.py", .data = script });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "server.py", a);
    defer a.free(path);
    var client = try mcp.Client.init(a, .{ .id = "fixture", .name = "Fixture", .program = "/usr/bin/python3", .args = &.{path}, .enabled = true, .bindings = &.{.{ .name = "material" }}, .environment = @constCast((&[_]ext.Value{.{ .name = "PATH", .value = "/fixture-only/bin" }})[0..]) });
    defer client.deinit();
    try client.discover(null);
    try std.testing.expectEqual(@as(usize, 1), client.tools.items.len);
    try std.testing.expect(client.tools.items[0].available);
    const result = try client.call(client.tools.items[0], "hello", null);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "HELLO") != null);
    try std.testing.expectError(error.InvalidToolArguments, client.call(client.tools.items[0], &@as([65]u8, @splat('x')), null));
    client.close();
    try std.testing.expect(client.process == null and client.closed);
}

const HttpFixture = struct {
    child: std.process.Child,
    endpoint: []u8,
    fn start(tmp: *std.testing.TmpDir, mode: []const u8) !HttpFixture {
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(root);
        const port_path = try std.fs.path.join(a, &.{ root, "port" });
        defer a.free(port_path);
        const trace_path = try std.fs.path.join(a, &.{ root, "trace" });
        defer a.free(trace_path);
        tmp.dir.deleteFile(std.testing.io, "port") catch {};
        var child = try std.process.spawn(std.testing.io, .{ .argv = &.{ "/usr/bin/python3", "-c", @embedFile("ai/test_fixtures/mcp_http.py"), port_path, trace_path, mode }, .stderr = .ignore });
        errdefer child.kill(std.testing.io);
        const clock = @import("ai/retry.zig").Clock{};
        for (0..250) |_| {
            const bytes = tmp.dir.readFileAlloc(std.testing.io, "port", a, .limited(32)) catch {
                clock.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            defer a.free(bytes);
            const port = std.fmt.parseInt(u16, bytes, 10) catch {
                clock.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            return .{ .child = child, .endpoint = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/mcp", .{port}) };
        }
        return error.FixtureTimeout;
    }
    fn deinit(self: *HttpFixture) void {
        self.child.kill(std.testing.io);
        a.free(self.endpoint);
    }
    fn server(self: *HttpFixture) ext.Server {
        return .{ .id = "http-fixture", .name = "HTTP fixture", .enabled = true, .transport = .http, .endpoint = self.endpoint, .timeout_ms = 3000, .bindings = &.{ .{ .name = "material" }, .{ .name = "same-schema" } } };
    }
};
test "v0.4 extensions HTTP SSE handles multiline frames unsupported client requests session headers and explicit close" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try HttpFixture.start(&tmp, "sse");
    defer fixture.deinit();
    var client = try mcp.Client.init(a, fixture.server());
    defer client.deinit();
    try client.discover(null);
    try std.testing.expectEqual(@as(usize, 2), client.tools.items.len);
    try std.testing.expectEqual(@as(f64, 2), client.progress);
    try std.testing.expectEqualStrings("halfway", client.progress_message);
    const gateway = @import("ai/extension_gateway.zig");
    const first = try gateway.Session.capability(a, fixture.server(), client.tools.items[0]);
    defer a.free(first);
    const second = try gateway.Session.capability(a, fixture.server(), client.tools.items[1]);
    defer a.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const reply = try client.call(client.tools.items[0], "http fixture", null);
    defer a.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "HTTP FIXTURE") != null);
    client.close();
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace", a, .limited(65536));
    defer a.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "DELETE") != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, "fixture-session") != null);
}
test "v0.4 extensions HTTP rejects redirects and unsupported negotiated versions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "redirect", "badversion" }) |mode| {
        var fixture = try HttpFixture.start(&tmp, mode);
        defer fixture.deinit();
        var client = try mcp.Client.init(a, fixture.server());
        defer client.deinit();
        if (std.mem.eql(u8, mode, "redirect")) try std.testing.expectError(error.McpHttpStatus, client.discover(null)) else try std.testing.expectError(error.UnsupportedMcpVersion, client.discover(null));
    }
}
test "v0.4 extensions credential transaction saves refs only preserves values and rolls back failures" {
    const store = @import("config/store.zig");
    const credentials = store.credentials;
    var memory: credentials.MemoryBackend = .{};
    defer memory.deinit();
    const previous = credentials.useBackendForTesting(memory.backend());
    defer credentials.restoreBackendForTesting(previous);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var values = [_]ext.Value{.{ .name = "TOKEN", .value = "mcp-secret-never-on-disk", .secret = true }};
    var servers = [_]ext.Server{.{ .id = "secrets", .name = "Secrets", .program = "/usr/bin/true", .environment = &values }};
    var value: cfg.Config = .{};
    value.ai.extensions.servers = &servers;
    try store.save(std.testing.io, tmp.dir, "config.toml", value);
    const source = try tmp.dir.readFileAlloc(std.testing.io, "config.toml", a, .limited(store.max_config_bytes));
    defer a.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "mcp-secret-never-on-disk") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "zw1_") != null);
    var loaded = try store.load(std.testing.io, tmp.dir, a, "config.toml");
    defer loaded.deinit(a);
    try std.testing.expectEqualStrings(values[0].value, loaded.value.ai.extensions.servers[0].environment[0].value);
    memory.fail_add_after = memory.additions;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var replacement = loaded.value;
    replacement.ai.extensions = try loaded.value.ai.extensions.clone(arena.allocator());
    replacement.ai.extensions.servers[0].environment[0].value = "replacement";
    try std.testing.expectError(error.CredentialStorageFailure, store.save(std.testing.io, tmp.dir, "config.toml", replacement));
    const unchanged = try tmp.dir.readFileAlloc(std.testing.io, "config.toml", a, .limited(store.max_config_bytes));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings(source, unchanged);
}

const host = @import("ai/host_tools.zig");
fn testContext() host.Context {
    return .{ .conversation_id = .{ .bytes = @splat(1) }, .task_id = .{ .bytes = @splat(2) }, .binding = .{ .group = 7 }, .binding_revision = 1, .grant_revision = 1 };
}
fn testInvocation(tool: []const u8, arguments: std.json.Value, wire: []const u8) !host.Invocation {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wire, &hash, .{});
    return .{ .context = testContext(), .authority = .conversation_context, .operation_id = 1, .turn_id = 1, .call_id = "extensions-call", .tool_id = tool, .arguments = arguments, .arguments_json = wire, .arguments_hash = hash, .canonical_arguments_hash = try @import("ai/canonical_arguments.zig").digest(a, arguments) };
}
const TestGate = struct {
    revoked: bool = false,
    approved: usize = 0,
    fn check(raw: *anyopaque, _: []const u8, _: bool, cancel: ?*@import("ai/provider.zig").CancelToken) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.revoked) return error.ExtensionRevoked;
        if (cancel) |token| if (token.isCancelled()) return error.CancelledBeforeDispatch;
    }
    fn approve(raw: *anyopaque, _: host.Invocation, _: ext.Server, _: ?[]const u8, _: ?*@import("ai/provider.zig").CancelToken) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.approved += 1;
    }
    fn gate(self: *@This()) @import("ai/extension_gateway.zig").Gate {
        return .{ .context = self, .check = check, .approve = approve };
    }
};
fn gatewayInvoke(session: *@import("ai/extension_gateway.zig").Session, journal: *@import("ai/lifecycle_runtime.zig").ProcessJournal, gate: *TestGate, tool: []const u8, wire: []const u8) !host.Result {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, wire, .{});
    defer parsed.deinit();
    return session.invoke(std.testing.io, gate.gate(), journal, try testInvocation(tool, parsed.value, wire), null, a);
}
test "v0.4 extensions gateway catalog actual call idempotent receipt and revocation" {
    const gateway = @import("ai/extension_gateway.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try HttpFixture.start(&tmp, "json");
    defer fixture.deinit();
    var servers = [_]ext.Server{fixture.server()};
    var session = try gateway.Session.init(a, .{ .servers = &servers }, "/test/extensions-gateway");
    defer session.deinit();
    const journal = try @import("ai/lifecycle_runtime.zig").ProcessJournal.acquire(.{ .data_root = "/test/extensions-gateway", .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    var gate: TestGate = .{};
    var catalog = try gatewayInvoke(&session, journal, &gate, "host.mcp_catalog", "{\"action\":\"tools\",\"server_id\":\"http-fixture\"}");
    defer catalog.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, catalog.status);
    try std.testing.expectEqual(@as(usize, 1), gate.approved);
    const reference = try gateway.Session.capability(a, servers[0], session.clients[0].?.tools.items[0]);
    defer a.free(reference);
    const wire = try std.json.Stringify.valueAlloc(a, .{ .capability_ref = reference, .request_key = "first", .arguments = .{ .text = "gateway test" } }, .{});
    defer a.free(wire);
    var result = try gatewayInvoke(&session, journal, &gate, "host.mcp_call", wire);
    defer result.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.blocks[0].structured, "GATEWAY TEST") != null);
    var replay = try gatewayInvoke(&session, journal, &gate, "host.mcp_call", wire);
    defer replay.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), gate.approved);
    try std.testing.expect(std.mem.indexOf(u8, replay.blocks[0].structured, "idempotent_reuse") != null);
    gate.revoked = true;
    var rejected = try gatewayInvoke(&session, journal, &gate, "host.mcp_call", wire);
    defer rejected.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.rejected, rejected.status);
    try std.testing.expect(!rejected.receipt.side_effect_started);
}
test "v0.4 extensions unknown MCP operation blocks changed request keys task and direct child after reopen" {
    const runtime = @import("ai/lifecycle_runtime.zig");
    const id = @import("host/identity.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var request: @import("ai/lifecycle_journal.zig").Request = .{ .context = testContext(), .tool_id = "host.mcp_call", .request_key = "first", .canonical_hash = @splat(3), .turn_id = 1, .call_id = "one" };
    var journal = try runtime.ProcessJournal.acquire(.{ .data_root = "/test/extensions-unknown", .dir = tmp.dir, .io = std.testing.io });
    const handle = try journal.beginMcp(request);
    try journal.update(handle, 1, .{ .stage = .dispatch_started, .local_released = false });
    journal.release();
    journal = try runtime.ProcessJournal.acquire(.{ .data_root = "/test/extensions-unknown", .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    request.request_key = "new-key";
    request.context.task_id = .generate();
    try std.testing.expectError(error.McpPreviousOutcomeUnknown, journal.beginMcp(request));
    request.context.child_origin = .{ .agent = .generate(), .parent = .{ .conversation = testContext().conversation_id, .agent = .generate(), .binding = 1, .environment = 1 }, .worker_generation = 1, .scope_revision = 1 };
    request.context.conversation_id = id.ConversationId.generate();
    try std.testing.expectError(error.McpPreviousOutcomeUnknown, journal.beginMcp(request));
}
test "v0.4 extensions child selection intersects parent frozen set without adding newly enabled services" {
    const gateway = @import("ai/extension_gateway.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var servers = [_]ext.Server{ .{ .id = "saved", .name = "Saved", .enabled = true, .program = "/usr/bin/true" }, .{ .id = "new", .name = "New", .enabled = true, .program = "/usr/bin/true" } };
    const selected = try gateway.select(arena.allocator(), .{ .servers = &servers }, &.{}, &.{"saved"});
    try std.testing.expectEqual(@as(usize, 1), selected.servers.len);
    try std.testing.expectEqualStrings("saved", selected.servers[0].id);
    const legacy = try gateway.select(arena.allocator(), .{ .servers = &servers }, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), legacy.servers.len);
}
test "v0.4 extensions local reimport preserves pinned old content rejects symlinks missing references and reserved manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "source");
    const source = try tmp.dir.realPathFileAlloc(std.testing.io, "source", a);
    defer a.free(source);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source/SKILL.md", .data = "---\r\nname: test-skill\r\ndescription: >-\r\n  Read the supplied\r\n  material only\r\n---\r\nold body\r\n" });
    var old = try skills.importLocal(a, std.testing.io, tmp.dir, source, null);
    defer old.deinit();
    try std.testing.expectEqualStrings("Read the supplied material only", old.skill.description);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source/SKILL.md", .data = "---\nname: test-skill\ndescription: next\n---\nnew body\n" });
    var next = try skills.importLocal(a, std.testing.io, tmp.dir, source, old.skill);
    defer next.deinit();
    try std.testing.expectEqualStrings(old.skill.id, next.skill.id);
    try std.testing.expect(!std.mem.eql(u8, old.skill.revision, next.skill.revision));
    const pinned = try skills.read(a, std.testing.io, tmp.dir, old.skill, "SKILL.md");
    defer a.free(pinned);
    try std.testing.expect(std.mem.indexOf(u8, pinned, "old body") != null);
    try tmp.dir.symLink(std.testing.io, "/etc/passwd", "source/outside", .{});
    try std.testing.expectError(error.UnsupportedSkillFile, skills.importLocal(a, std.testing.io, tmp.dir, source, null));
    try tmp.dir.deleteFile(std.testing.io, "source/outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source/.package.json", .data = "{}" });
    try std.testing.expectError(error.ReservedSkillFile, skills.importLocal(a, std.testing.io, tmp.dir, source, null));
    try tmp.dir.deleteFile(std.testing.io, "source/.package.json");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source/SKILL.md", .data = "---\nname: test-skill\ndescription: next\n---\n[missing](references/missing.txt)\n" });
    try std.testing.expectError(error.MissingSkillResource, skills.importLocal(a, std.testing.io, tmp.dir, source, null));
}
test "v0.4 extensions MCP cancellation releases request without retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try HttpFixture.start(&tmp, "hang");
    defer fixture.deinit();
    var server = fixture.server();
    server.timeout_ms = 1000;
    var client = try mcp.Client.init(a, server);
    defer client.deinit();
    try client.discover(null);
    var cancel: @import("ai/provider.zig").CancelToken = .{};
    const Stop = struct {
        fn run(token: *@import("ai/provider.zig").CancelToken) void {
            (@import("ai/retry.zig").Clock{}).sleep(100 * std.time.ns_per_ms);
            token.cancel();
        }
    };
    const thread = try std.Thread.spawn(.{}, Stop.run, .{&cancel});
    defer thread.join();
    try std.testing.expectError(error.Cancelled, client.call(client.tools.items[0], "once only", &cancel));
    try std.testing.expect(client.closed);
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace", a, .limited(65536));
    defer a.free(trace);
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, trace, "\"method\": \"tools/call\"");
    while (it.next() != null) count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}
test "v0.4 extensions settings save merge stale callback revert and no process autostart" {
    const runtime = @import("config/runtime_config.zig");
    const Controller = @import("config/settings_controller.zig").Controller;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var target = try runtime.RuntimeConfig.loadOrDefault(std.testing.io, tmp.dir, a, "config.toml");
    defer target.deinit();
    var controller = try Controller.init(a, target.value);
    defer controller.deinit();
    var servers = [_]ext.Server{.{ .id = "draft", .name = "Draft", .program = "/does/not/exist", .enabled = true }};
    const before = target.value.agentPolicyRevision();
    try controller.setExtensions(.{ .servers = &servers });
    var request = try controller.beginSave(&target, false);
    defer request.deinit();
    try target.updateSetting(std.testing.io, tmp.dir, "ui", "font_size", .{ .unsigned = 18 });
    try std.testing.expectError(error.StaleConfigRevision, controller.completeSave(std.testing.io, tmp.dir, &target, &request));
    try controller.save(std.testing.io, tmp.dir, &target);
    try std.testing.expectEqual(@as(u8, 18), target.value.ui.font_size);
    try std.testing.expectEqualStrings("/does/not/exist", target.value.ai.extensions.servers[0].program);
    try std.testing.expect(target.value.agentPolicyRevision() > before);
    const policy = target.value.agentPolicyRevision();
    servers[0].enabled = false;
    try controller.setExtensions(.{ .servers = &servers });
    try controller.save(std.testing.io, tmp.dir, &target);
    try std.testing.expectEqual(policy, target.value.agentPolicyRevision());
    try controller.setExtensions(.{});
    try controller.discardLatest(&target);
    try std.testing.expectEqual(@as(usize, 1), controller.model.value.ai.extensions.servers.len);
}
test "v0.4 extensions MCP reflected credentials never become tool output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try HttpFixture.start(&tmp, "json");
    defer fixture.deinit();
    var server = fixture.server();
    var headers = [_]ext.Value{.{ .name = "X-Fixture", .value = "REFLECTED_SECRET", .secret = true }};
    server.headers = &headers;
    var client = try mcp.Client.init(a, server);
    defer client.deinit();
    try client.discover(null);
    try std.testing.expectError(error.McpSecretReflected, client.call(client.tools.items[0], "REFLECTED_SECRET", null));
}

test "v0.4 extensions schema change after catalog rejects capability before business dispatch" {
    const gateway = @import("ai/extension_gateway.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try HttpFixture.start(&tmp, "schema-change");
    defer fixture.deinit();
    var servers = [_]ext.Server{fixture.server()};
    var session = try gateway.Session.init(a, .{ .servers = &servers }, "/test/extensions-schema");
    defer session.deinit();
    const journal = try @import("ai/lifecycle_runtime.zig").ProcessJournal.acquire(.{ .data_root = "/test/extensions-schema", .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    var gate: TestGate = .{};
    var catalog = try gatewayInvoke(&session, journal, &gate, "host.mcp_catalog", "{\"action\":\"tools\",\"server_id\":\"http-fixture\"}");
    defer catalog.deinit(a);
    const reference = try gateway.Session.capability(a, servers[0], session.clients[0].?.tools.items[0]);
    defer a.free(reference);
    const wire = try std.json.Stringify.valueAlloc(a, .{ .capability_ref = reference, .request_key = "schema-check", .arguments = .{ .text = "supplied text" } }, .{});
    defer a.free(wire);
    var result = try gatewayInvoke(&session, journal, &gate, "host.mcp_call", wire);
    defer result.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.rejected, result.status);
    try std.testing.expect(!result.receipt.side_effect_started);
    try std.testing.expect(std.mem.indexOf(u8, result.blocks[0].structured, "McpSchemaChanged") != null);
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace", a, .limited(65536));
    defer a.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "tools/call") == null);
}

test "v0.4 extensions selected SKILL FIFO is rejected before blocking open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "SKILL.md" });
    defer a.free(path);
    const fifo = try a.dupeSentinel(u8, path, 0);
    defer a.free(fifo);
    const Native = struct {
        extern "c" fn mkfifo([*:0]const u8, u16) c_int;
    };
    try std.testing.expectEqual(@as(c_int, 0), Native.mkfifo(fifo, 0o600));
    try std.testing.expectError(error.UnsupportedSkillFile, skills.importLocal(a, std.testing.io, tmp.dir, path, null));
}

test "v0.4 readonly task hides effect tools and rejects forged dynamic dispatch under auto policy" {
    const provider = @import("ai/provider.zig");
    const loop_mod = @import("ai/tool_loop.zig");
    const plugin = @import("ai/plugin_tools.zig");
    const contributions = [_]host.Contribution{
        .{ .authority = .conversation_context, .definition = .{ .id = "host.test_read", .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}" } },
        .{ .authority = .conversation_context, .definition = .{ .id = "host.test_write", .effect = .resource_write, .schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{}}" } },
    };
    var table = try plugin.RequestTable.initWithHost(a, .{ .owner = testContext().binding, .members = .{} }, &.{}, &.{}, testContext(), &contributions);
    defer table.deinit();
    const defs = try plugin.providerDefinitions(&table, a);
    defer a.free(defs);
    var loop = loop_mod.Loop.init(a, .{ .owner = testContext().binding, .members = .{} }, 1, .{});
    defer loop.deinit();
    loop.read_only = true;
    try loop.start(.{ .model = "fixture", .system = "", .messages = &.{.{ .role = .user, .content = "verify only" }}, .tools = defs, .tool_table = &table });
    const request = try loop.nextRequest();
    try std.testing.expectEqual(@as(usize, 1), request.tools.len);
    const Fake = struct {
        fn execute(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
            return error.ShouldNeverDispatch;
        }
    };
    var dummy: u8 = 0;
    try loop.complete("", &.{.{ .id = "forged", .name = "host__test_uwrite", .arguments = "{}" }}, .{ .context = &dummy, .execute = Fake.execute }, .{ .mode = .auto }, 1, null);
    try std.testing.expect(std.mem.indexOf(u8, loop.records.items[0].result_body.?, "ObservationOnlyTask") != null);
    try std.testing.expect(!loop.records.items[0].dispatched);
}

test "v0.4 extensions collections preserve sibling links and import resources without file count or size caps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "collection/one/references");
    try tmp.dir.createDirPath(std.testing.io, "collection/group/two");
    try tmp.dir.createDirPath(std.testing.io, "collection/.git/ignored");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "collection/one/SKILL.md", .data = "---\nname: one\ndescription: First\n---\n[other](../two/SKILL.md) [ref](references/large.txt)\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "collection/group/two/SKILL.md", .data = "---\nname: two\ndescription: Second\n---\nBody\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "collection/.git/ignored/SKILL.md", .data = "invalid" });
    const large = try a.alloc(u8, 1024 * 1024);
    defer a.free(large);
    @memset(large, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "collection/one/references/large.txt", .data = large });
    for (0..2050) |i| {
        const name = try std.fmt.allocPrint(a, "collection/one/references/{d}.txt", .{i});
        defer a.free(name);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "reference" });
    }
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "collection", a);
    defer a.free(root);
    const paths = try skills.sources(a, std.testing.io, root);
    defer {
        for (paths) |path| a.free(path);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    const one = if (std.mem.endsWith(u8, paths[0], "/one")) paths[0] else paths[1];
    var imported = try skills.importLocal(a, std.testing.io, tmp.dir, one, null);
    defer imported.deinit();
    const read = try skills.read(a, std.testing.io, tmp.dir, imported.skill, "references/large.txt");
    defer a.free(read);
    try std.testing.expectEqualSlices(u8, large, read);
    try std.testing.expectError(error.InvalidSkillPath, skills.read(a, std.testing.io, tmp.dir, imported.skill, "../two/SKILL.md"));
    // Opaque executable resources are copied without text decoding or the old
    // 8 MiB cap. This also crosses the previous 64 MiB package limit.
    try tmp.dir.createDirPath(std.testing.io, "collection/one/scripts");
    var binary = try tmp.dir.createFile(std.testing.io, "collection/one/scripts/tool", .{});
    try binary.setLength(std.testing.io, 65 * 1024 * 1024);
    binary.close(std.testing.io);
    var uncapped = try skills.importLocal(a, std.testing.io, tmp.dir, one, null);
    defer uncapped.deinit();
    try std.testing.expect(uncapped.file_count > 2048);
    try std.testing.expect(uncapped.total_bytes > 64 * 1024 * 1024);
    try std.testing.expectError(error.SkillResourceNotText, skills.read(a, std.testing.io, tmp.dir, uncapped.skill, "scripts/tool"));
}

test "v0.4 extensions multi parameter MCP calls validate forward schema and preserve approval idempotency" {
    const gateway = @import("ai/extension_gateway.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try HttpFixture.start(&tmp, "multi");
    defer fixture.deinit();
    var servers = [_]ext.Server{fixture.server()};
    var session = try gateway.Session.init(a, .{ .servers = &servers }, "/test/extensions-multi");
    defer session.deinit();
    const journal = try @import("ai/lifecycle_runtime.zig").ProcessJournal.acquire(.{ .data_root = "/test/extensions-multi", .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    var gate: TestGate = .{};
    var catalog = try gatewayInvoke(&session, journal, &gate, "host.mcp_catalog", "{\"action\":\"tools\",\"server_id\":\"http-fixture\"}");
    defer catalog.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, catalog.status);
    try std.testing.expect(std.mem.indexOf(u8, catalog.blocks[0].structured, "input_schema") != null);
    const reference = try gateway.Session.capability(a, servers[0], session.clients[0].?.tools.items[0]);
    defer a.free(reference);
    const bad = try std.json.Stringify.valueAlloc(a, .{ .capability_ref = reference, .request_key = "invalid", .arguments = .{ .query = "search", .limit = "wrong type" } }, .{});
    defer a.free(bad);
    var rejected = try gatewayInvoke(&session, journal, &gate, "host.mcp_call", bad);
    defer rejected.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.rejected, rejected.status);
    try std.testing.expectEqual(@as(usize, 1), gate.approved);
    const wire = try std.json.Stringify.valueAlloc(a, .{ .capability_ref = reference, .request_key = "multi-once", .arguments = .{ .query = "search", .limit = 3, .options = .{ .tags = [_][]const u8{ "a", "b" } } } }, .{});
    defer a.free(wire);
    var reply = try gatewayInvoke(&session, journal, &gate, "host.mcp_call", wire);
    defer reply.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, reply.status);
    try std.testing.expectEqual(@as(usize, 2), gate.approved);
    // The same arguments in another JSON key order must not dispatch again.
    const reordered = try std.fmt.allocPrint(a, "{{\"capability_ref\":\"{s}\",\"request_key\":\"multi-once\",\"arguments\":{{\"options\":{{\"tags\":[\"a\",\"b\"]}},\"limit\":3,\"query\":\"search\"}}}}", .{reference});
    defer a.free(reordered);
    var replay = try gatewayInvoke(&session, journal, &gate, "host.mcp_call", reordered);
    defer replay.deinit(a);
    try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, replay.status);
    try std.testing.expectEqual(@as(usize, 2), gate.approved);
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace", a, .limited(65536));
    defer a.free(trace);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "\"method\": \"tools/call\"") / 2);
    try std.testing.expect(std.mem.indexOf(u8, trace, "\"limit\": 3") != null);
}

test "v0.4 extensions skill gateway pages escaped unicode text without dropping bytes" {
    const gateway = @import("ai/extension_gateway.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "source");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source/SKILL.md", .data = "---\nname: paged\ndescription: Paging test\n---\nBody\n" });
    const text = try a.alloc(u8, 90 * 1024);
    defer a.free(text);
    for (0..text.len / 3) |i| @memcpy(text[i * 3 ..][0..3], if (i % 2 == 0) "中" else "\n\t\\");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source/large.txt", .data = text });
    const source = try tmp.dir.realPathFileAlloc(std.testing.io, "source", a);
    defer a.free(source);
    var imported = try skills.importLocal(a, std.testing.io, tmp.dir, source, null);
    defer imported.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var session = try gateway.Session.init(a, .{ .skills = &.{imported.skill} }, root);
    defer session.deinit();
    const journal = try @import("ai/lifecycle_runtime.zig").ProcessJournal.acquire(.{ .data_root = root, .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    var gate: TestGate = .{};
    var offset: usize = 0;
    while (true) {
        const wire = try std.json.Stringify.valueAlloc(a, .{ .action = "read", .skill_id = imported.skill.id, .revision = imported.skill.revision, .resource = "large.txt", .offset = offset }, .{});
        defer a.free(wire);
        var reply = try gatewayInvoke(&session, journal, &gate, "host.skills", wire);
        defer reply.deinit(a);
        try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, reply.status);
        const body = try std.json.parseFromSlice(std.json.Value, a, reply.blocks[0].structured, .{});
        defer body.deinit();
        const chunk = body.value.object.get("content").?.string;
        try std.testing.expect(std.unicode.utf8ValidateSlice(chunk));
        try std.testing.expectEqualSlices(u8, text[offset..][0..chunk.len], chunk);
        offset += chunk.len;
        const next = body.value.object.get("next_offset").?;
        if (next == .null) break;
        try std.testing.expectEqual(offset, @as(usize, @intCast(next.integer)));
    }
    try std.testing.expectEqual(text.len, offset);
}

test "v0.4 extensions sizes use readable binary units" {
    const sizes = @import("ai/extension_sizes.zig");
    const values = [_]u64{ 0, 512, 1024, 1536, 8 * 1024 * 1024, 936824 };
    const expected = [_][]const u8{ "0 B", "512 B", "1 KiB", "1.50 KiB", "8 MiB", "914.87 KiB" };
    for (values, expected) |bytes, label| {
        const formatted = try sizes.format(a, bytes);
        defer a.free(formatted);
        try std.testing.expectEqualStrings(label, formatted);
    }
}

test "v0.4 extensions standard MCP schemas refs unions nullable patterns and structured output work over HTTP" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "standard", "bad-output" }) |mode| {
        var fixture = try HttpFixture.start(&tmp, mode);
        defer fixture.deinit();
        var client = try mcp.Client.init(a, fixture.server());
        defer client.deinit();
        try client.discover(null);
        const tool = client.tools.items[0];
        try std.testing.expect(tool.available and tool.output_schema != null);
        const good = try std.json.parseFromSlice(std.json.Value, a, "{\"target\":{\"host\":\"example\",\"port\":443},\"filter\":null,\"limit\":\"all\",\"mode\":\"read\"}", .{});
        defer good.deinit();
        for ([_][]const u8{
            "{\"target\":{\"host\":\"INVALID\"},\"mode\":\"read\"}",
            "{\"target\":{\"host\":\"example\",\"port\":0},\"mode\":\"read\"}",
            "{\"target\":{\"host\":\"example\"},\"mode\":\"invalid\"}",
            "{\"target\":{\"host\":\"example\"},\"mode\":\"read\",\"extra\":1}",
        }) |wire| {
            const bad = try std.json.parseFromSlice(std.json.Value, a, wire, .{});
            defer bad.deinit();
            try std.testing.expectError(error.InvalidToolArguments, client.validateCallArguments(tool, bad.value));
        }
        if (std.mem.eql(u8, mode, "bad-output")) {
            try std.testing.expectError(error.InvalidMcpOutput, client.callArguments(tool, good.value, null));
        } else {
            const body = try client.callArguments(tool, good.value, null);
            defer a.free(body);
            try std.testing.expect(std.mem.indexOf(u8, body, "structuredContent") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"ok\"") != null);
        }
    }
}

test "v0.4 extensions MCP negotiates older versions and accepts servers without tools" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "legacy-version", "no-tools" }) |mode| {
        var fixture = try HttpFixture.start(&tmp, mode);
        defer fixture.deinit();
        var client = try mcp.Client.init(a, fixture.server());
        defer client.deinit();
        try client.discover(null);
        if (std.mem.eql(u8, mode, "no-tools")) {
            try std.testing.expectEqual(@as(usize, 0), client.tools.items.len);
        } else {
            try std.testing.expectEqualStrings("2025-03-26", client.negotiated_version);
            const body = try client.call(client.tools.items[0], "negotiated", null);
            defer a.free(body);
            try std.testing.expect(std.mem.indexOf(u8, body, "NEGOTIATED") != null);
        }
    }
}

test "v0.4 extensions MCP preserves all standard content types and pages full results without redispatch" {
    const gateway = @import("ai/extension_gateway.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const journal = try @import("ai/lifecycle_runtime.zig").ProcessJournal.acquire(.{ .data_root = root, .dir = tmp.dir, .io = std.testing.io });
    defer journal.release();
    for ([_][]const u8{ "mixed", "large" }) |mode| {
        tmp.dir.deleteFile(std.testing.io, "trace") catch {};
        var fixture = try HttpFixture.start(&tmp, mode);
        defer fixture.deinit();
        var servers = [_]ext.Server{fixture.server()};
        var session = try gateway.Session.init(a, .{ .servers = &servers }, root);
        defer session.deinit();
        var gate: TestGate = .{};
        var catalog = try gatewayInvoke(&session, journal, &gate, "host.mcp_catalog", "{\"action\":\"tools\",\"server_id\":\"http-fixture\"}");
        defer catalog.deinit(a);
        const reference = try gateway.Session.capability(a, servers[0], session.clients[0].?.tools.items[0]);
        defer a.free(reference);
        const wire = try std.json.Stringify.valueAlloc(a, .{ .capability_ref = reference, .request_key = mode, .arguments = .{ .text = mode } }, .{});
        defer a.free(wire);
        var reply = try gatewayInvoke(&session, journal, &gate, "host.mcp_call", wire);
        defer reply.deinit(a);
        try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, reply.status);
        try reply.validate(testContext(), 1);
        try std.testing.expectEqual(@as(usize, 1), session.saved.items.len);
        const saved = session.saved.items[0];
        if (std.mem.eql(u8, mode, "mixed")) {
            try std.testing.expectEqual(@as(usize, 1), reply.images.len);
            // A decoded MCP image must become a real tool image in the next
            // provider request, rather than base64 text in the transcript.
            const plugin = @import("ai/plugin_tools.zig");
            const loop_mod = @import("ai/tool_loop.zig");
            const provider = @import("ai/provider.zig");
            var table = try plugin.RequestTable.initWithHost(a, .{ .owner = testContext().binding, .members = .{} }, &.{}, &.{}, testContext(), &.{.{ .authority = .conversation_context, .definition = .{ .id = "host.test_image", .schema = "{\"type\":\"object\",\"additionalProperties\":false}" } }});
            defer table.deinit();
            const definitions = try plugin.providerDefinitions(&table, table.arena.allocator());
            const Backend = struct {
                image: @import("ai/image_attachments.zig").ContentRef,
                fn legacy(_: *anyopaque, _: loop_mod.Invocation, _: std.mem.Allocator, _: ?*provider.CancelToken) !loop_mod.Outcome {
                    return error.UnexpectedLegacyDispatch;
                }
                fn invoke(raw: *anyopaque, invocation: host.Invocation, allocator: std.mem.Allocator, _: ?*provider.CancelToken) !host.Result {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    const refs = try allocator.dupe(@import("ai/image_attachments.zig").ContentRef, &.{self.image.retain()});
                    return .{ .status = .succeeded, .images = refs, .receipt = .{ .conversation_id = invocation.context.conversation_id, .task_id = invocation.context.task_id, .operation_id = invocation.operation_id, .binding_revision = invocation.context.binding_revision } };
                }
            };
            var backend: Backend = .{ .image = reply.images[0] };
            var loop = loop_mod.Loop.init(a, .{ .owner = testContext().binding, .members = .{} }, 1, .{ .context_window = 100000 });
            defer loop.deinit();
            try loop.start(.{ .model = "gpt-4o", .system = "", .messages = &.{}, .tools = definitions, .tool_table = &table, .vision = true, .tool_images = true });
            try loop.complete("", &.{.{ .id = "mcp-image", .name = definitions[0].name(), .arguments = "{}" }}, .{ .context = &backend, .execute = Backend.legacy, .execute_host = Backend.invoke }, .{}, 1, null);
            const next_request = try loop.nextRequest();
            try std.testing.expectEqual(@as(usize, 1), next_request.messages[next_request.messages.len - 1].images.len);

            try std.testing.expectEqual(@as(u32, 1), reply.images[0].content().?.width);
            try std.testing.expectEqual(@as(usize, 4), saved.files.len);
            try std.testing.expect(std.mem.indexOf(u8, reply.blocks[0].structured, "audio/wav") != null);
            try std.testing.expect(std.mem.indexOf(u8, reply.blocks[0].structured, "resource_link") != null);
        }
        var offset: usize = 0;
        var total: usize = 0;
        while (true) {
            const read_wire = try std.json.Stringify.valueAlloc(a, .{ .result_ref = saved.reference, .resource = "result.json", .offset = offset }, .{});
            defer a.free(read_wire);
            var page = try gatewayInvoke(&session, journal, &gate, "host.mcp_result", read_wire);
            defer page.deinit(a);
            try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.succeeded, page.status);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, page.blocks[0].structured, .{});
            defer parsed.deinit();
            const text = parsed.value.object.get("content").?.string;
            offset += text.len;
            total = @intCast(parsed.value.object.get("total_bytes").?.integer);
            if (parsed.value.object.get("next_offset").? == .null) break;
            try std.testing.expectEqual(offset, @as(usize, @intCast(parsed.value.object.get("next_offset").?.integer)));
        }
        try std.testing.expectEqual(total, offset);
        try std.testing.expectEqual(@as(usize, 2), gate.approved);
        const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace", a, .limited(1024 * 1024));
        defer a.free(trace);
        var lines = std.mem.splitScalar(u8, trace, '\n');
        var calls: usize = 0;
        var previous_id: ?i64 = null;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const record = try std.json.parseFromSlice(std.json.Value, a, line, .{});
            defer record.deinit();
            const method = record.value.object.get("method").?;
            if (method == .string and std.mem.eql(u8, method.string, "tools/call")) {
                const id = record.value.object.get("id").?.integer;
                if (previous_id) |old_id| try std.testing.expect(old_id != id);
                previous_id = id;
                calls += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), calls);
        gate.revoked = true;
        const read_wire = try std.json.Stringify.valueAlloc(a, .{ .result_ref = saved.reference }, .{});
        defer a.free(read_wire);
        var denied = try gatewayInvoke(&session, journal, &gate, "host.mcp_result", read_wire);
        defer denied.deinit(a);
        try std.testing.expectEqual(@import("ai/plugin_tools.zig").Status.rejected, denied.status);
    }
}

test "v0.4 extensions modern discovery per-request metadata opaque state and non-object output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try HttpFixture.start(&tmp, "modern");
    defer fixture.deinit();
    const Handler = struct {
        roots: usize = 0,
        resumed: usize = 0,
        fn request(raw: *anyopaque, allocator: std.mem.Allocator, method: []const u8, _: std.json.Value, _: ?*@import("ai/provider.zig").CancelToken) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, method, "roots/list")) {
                self.roots += 1;
                return allocator.dupe(u8, "{\"roots\":[{\"uri\":\"file:///tmp/selected-root\"}]}");
            }
            if (!std.mem.eql(u8, method, "host/mcp_continue")) return error.UnexpectedMcpRequest;
            self.resumed += 1;
            return allocator.dupe(u8, "{}");
        }
    };
    var handler: Handler = .{};
    var client = try mcp.Client.init(a, fixture.server());
    defer client.deinit();
    client.handler = .{ .context = &handler, .request = Handler.request };
    try client.discover(null);
    try std.testing.expectEqualStrings("2026-07-28", client.negotiated_version);
    try std.testing.expect(client.modern and client.session_id[0] == 0);
    const reply = try client.call(client.tools.items[0], "modern", null);
    defer a.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "MODERN COMPLETE") != null);
    try std.testing.expectEqual(@as(usize, 20), handler.roots);
    try std.testing.expectEqual(@as(usize, 20), handler.resumed);
    const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace", a, .limited(32768));
    defer a.free(trace);
    try std.testing.expect(std.mem.indexOf(u8, trace, "initialize") == null);
    var lines = std.mem.splitScalar(u8, trace, '\n');
    var calls: usize = 0;
    var previous_id: ?i64 = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const record = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer record.deinit();
        const method = record.value.object.get("method").?;
        if (method == .string and std.mem.eql(u8, method.string, "tools/call")) {
            const id = record.value.object.get("id").?.integer;
            if (previous_id) |old_id| try std.testing.expect(old_id != id);
            previous_id = id;
            calls += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 21), calls);
}

test "v0.4 extensions modern unknown input invalid results and explicit unsupported versions fail closed" {
    for ([_][]const u8{ "modern-unknown-input", "modern-bad-result", "modern-unsupported" }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var fixture = try HttpFixture.start(&tmp, mode);
        defer fixture.deinit();
        const Handler = struct {
            fn request(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: std.json.Value, _: ?*@import("ai/provider.zig").CancelToken) ![]u8 {
                return error.HandlerMustNotRun;
            }
        };
        var flag: u8 = 0;
        var client = try mcp.Client.init(a, fixture.server());
        defer client.deinit();
        client.handler = .{ .context = &flag, .request = Handler.request };
        if (std.mem.eql(u8, mode, "modern-unknown-input")) {
            try client.discover(null);
            try std.testing.expectError(error.McpMethodNotAllowed, client.call(client.tools.items[0], "modern", null));
        } else if (std.mem.eql(u8, mode, "modern-bad-result")) try std.testing.expectError(error.InvalidMcpResponse, client.discover(null)) else try std.testing.expectError(error.UnsupportedMcpVersion, client.discover(null));
        const trace = try tmp.dir.readFileAlloc(std.testing.io, "trace", a, .limited(32768));
        defer a.free(trace);
        try std.testing.expect(std.mem.indexOf(u8, trace, "initialize") == null);
    }
}
