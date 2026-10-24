//! API 2 acceptance fixture. Kept out of the production executable registry.
const std = @import("std");
const fixture = @import("plugins/fixture_probe/plugin.zig");
const model = @import("plugins/fixture_probe/model.zig");
const sessions = @import("host/session_host.zig");
const identity = @import("host/identity.zig");
const content = @import("host/content_context.zig");
const frames = @import("host/frame_texture_sink.zig");
const tools = @import("ai/plugin_tools.zig");
const scope = @import("ai/tool_scope.zig");
const hosts = @import("config/hosts.zig");
const resolver = @import("host/connection_config_resolver.zig");
const contexts = @import("host/host_context.zig");
const challenges = @import("host/challenge_host.zig");
const a = std.testing.allocator;
const target: sessions.AttachmentTarget = .{ .window_id = @fromBackingInt(1), .workspace_id = @fromBackingInt(1) };

test "fixture native editor mounts owned text models in its host slot" {
    const ui = @import("ui");
    const Callbacks = struct {
        fn changed(_: *anyopaque) void {}
        fn submit(_: *anyopaque, _: @import("config/connection_envelope.zig").Envelope, _: @import("host/plugin_ui_contract.zig").SubmitIntent) !void {}
    };
    const cx = try ui.Cx.init(a, std.testing.io);
    defer cx.deinit();
    cx.setViewport(860, 480);
    cx.root = try ui.box(cx, .{ .width = .fill(), .height = .fill() }, .{});
    const editor_scope = try ui.Scope.init(a, null, cx.owner);
    defer editor_scope.dispose();
    var callback_context: u8 = 0;
    const editor = try @import("plugins/fixture_probe/views.zig").mountEditor(null, .{
        .cx = cx,
        .scope = editor_scope,
        .slot = cx.root.?,
        .protocol_id = model.protocol_id,
        .draft_revision = 1,
        .events = .{ .context = &callback_context, .changed = Callbacks.changed, .submit = Callbacks.submit },
    });
    defer editor.vtable.unmount(editor.context);
    cx.layout();
    try std.testing.expect(cx.root.?.children.items.len > 0);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const value = try editor.vtable.snapshot(editor.context, arena.allocator());
    try std.testing.expectEqualStrings(model.protocol_id, value.protocol_id);
}
const ContextDriver = struct {
    challenge: challenges.Host,
    show_grid: bool = true,
    fn preference(ptr: *anyopaque, plugin_id: []const u8, key: []const u8) ?[]const u8 {
        const self: *ContextDriver = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, plugin_id, model.protocol_id) or !std.mem.eql(u8, key, "show_grid")) return null;
        return if (self.show_grid) "true" else "false";
    }
    fn create(ptr: *anyopaque, owner: identity.SessionHandle, operation: sessions.OperationKey, attachment: contexts.Target) !contexts.HostContext {
        const self: *ContextDriver = @ptrCast(@alignCast(ptr));
        return .{ .owner = owner, .operation = operation, .target = attachment, .challenges = &self.challenge, .preferences = .{ .context = self, .plugin_id = model.protocol_id, .read_value = preference } };
    }
    fn inject(self: *ContextDriver, host: *sessions.SessionHost) void {
        host.setContextFactory(.{ .context = self, .create = create });
    }
    fn ready(self: *ContextDriver, host: *sessions.SessionHost, plugin: *fixture.Plugin) !void {
        _ = try host.pollControllers();
        for (plugin.runtimes.items) |runtime| if (runtime.phase == .authenticating) try self.challenge.submitAnswer(runtime.owner, runtime.challenge_id, runtime.owner.generation, .{ .secret_input = "controlled-test-input" }, runtime.challenge_deadline - 1);
        _ = try host.pollControllers();
        _ = try host.pollControllers();
    }
};

test "fixture autonomous conditional editor offline references secrets and stale child/probe" {
    var editor = model.Editor.init(a);
    defer editor.deinit();
    try std.testing.expectEqual(@as(usize, 2), editor.sectionCount());
    try editor.setSecret("connect-only-secret");
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const saved = try editor.snapshot(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, saved.payload, "connect-only-secret") == null);
    editor.asset_id = @fromBackingInt(42);
    editor.asset_revision = 7;
    editor.group_id = @fromBackingInt(9);
    try editor.changeName("renamed");
    const edited = try editor.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(u64, 42), @backingInt(edited.id));
    try std.testing.expectEqual(@as(u64, 7), edited.revision);
    try std.testing.expectEqual(@as(u64, 9), @backingInt(edited.group_id.?));
    var assets: hosts.Registry = .{ .arena = .init(a), .hosts = &.{} };
    defer assets.deinit();
    const ssh = try assets.add(.{ .name = "offline SSH", .host = "unreachable.invalid", .user = "tester", .auth_mode = .password });
    try editor.setRouted(true);
    try std.testing.expectEqual(@as(usize, 4), editor.sectionCount());
    try std.testing.expectError(error.MissingSshReference, editor.snapshot(arena.allocator()));
    const revision = editor.revision;
    try std.testing.expect(try editor.applyChild(revision, ssh.id, ssh.revision));
    try std.testing.expect(!try editor.applyChild(revision, ssh.id, ssh.revision));
    var route = try editor.freezeRoute(resolver.Resolver.init(&assets), a);
    defer route.deinit();
    try std.testing.expectEqual(ssh.revision, route.hops[0].revision);
    var changed_host = assets.hosts[0];
    changed_host.host = "changed.invalid";
    const updated = try assets.update(ssh, changed_host);
    var fresh_route = try editor.freezeRoute(resolver.Resolver.init(&assets), a);
    defer fresh_route.deinit();
    try std.testing.expectEqual(ssh.revision, route.hops[0].revision);
    try std.testing.expectEqual(updated.revision, fresh_route.hops[0].revision);
    changed_host = assets.hosts[0];
    changed_host.protocol = .sftp;
    const wrong_protocol = try assets.update(updated, changed_host);
    try std.testing.expectError(error.ProtocolMismatch, editor.freezeRoute(resolver.Resolver.init(&assets), a));
    try assets.remove(wrong_protocol);
    try std.testing.expectError(error.MissingRouteReference, editor.freezeRoute(resolver.Resolver.init(&assets), a));
    const probe_revision = editor.beginProbe();
    try editor.changeName("updated draft");
    try std.testing.expect(!editor.finishProbe(probe_revision));
    _ = editor.beginProbe();
    editor.cancelProbe();
    try std.testing.expect(!editor.finishProbe(editor.revision));
    editor.clearSecrets();
    try std.testing.expectEqual(@as(usize, 0), editor.secret_len);
    for (editor.secret) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "fixture common open lifecycle dedup nonterminal capabilities independent close stale generation" {
    var controller_context: ContextDriver = .{ .challenge = challenges.Host.init(a) };
    defer controller_context.challenge.deinit();
    const plugin = try fixture.Plugin.init(a);
    defer plugin.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{plugin.manifest()}, &.{plugin.renderer()});
    defer host.deinit();
    controller_context.inject(&host);
    var editor = model.Editor.init(a);
    defer editor.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const envelope = try editor.snapshot(arena.allocator());
    const first = try host.open(envelope, .{ .request_key = 1, .target = target });
    const again = try host.open(envelope, .{ .request_key = 1, .target = target });
    try std.testing.expect(first.handle.eql(again.handle));
    controller_context.show_grid = false;
    const second = try host.open(envelope, .{ .request_key = 2, .target = target });
    try std.testing.expect(!first.handle.eql(second.handle));
    try std.testing.expectEqual(@as(usize, 2), plugin.creates);
    try controller_context.ready(&host, plugin);
    try std.testing.expect(plugin.runtimeFor(first.handle).?.authenticated);
    try std.testing.expect(plugin.runtimeFor(first.handle).?.show_grid);
    try std.testing.expect(!plugin.runtimeFor(second.handle).?.show_grid);
    try std.testing.expect(host.queryTypedService(first.handle, fixture.Lifecycle, fixture.lifecycle_key) == .available);
    const Exec = sessions.LegacyService(.exec);
    try std.testing.expect(host.queryTypedService(first.handle, Exec, .{ .name = "exec" }) == .unsupported);
    try std.testing.expect(host.queryTypedService(first.handle, sessions.LegacyService(.transfer), .{ .name = "transfer" }) == .unsupported);
    try std.testing.expect(host.queryTypedService(first.handle, sessions.LegacyService(.terminal), .{ .name = "terminal" }) == .unsupported);
    const binding = plugin.runtimeFor(first.handle).?.binding;
    try std.testing.expectError(error.StaleBinding, binding.borrow(fixture.Lifecycle, fixture.lifecycle_key, try first.handle.nextGeneration()));
    _ = try host.requestClose(first.handle, .{});
    try std.testing.expectEqual(@as(usize, 1), plugin.releases);
    try std.testing.expect(plugin.runtimeFor(second.handle).?.phase == .ready);
    _ = try host.requestClose(first.handle, .{});
    try std.testing.expectEqual(@as(usize, 1), plugin.releases);
    _ = try host.requestClose(second.handle, .{});
    try std.testing.expectEqual(@as(usize, 2), plugin.releases);
}

test "fixture connect-time challenge has no default refuses stale empty cancelled and expired replies" {
    var context: ContextDriver = .{ .challenge = challenges.Host.init(a) };
    defer context.challenge.deinit();
    const plugin = try fixture.Plugin.init(a);
    defer plugin.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{plugin.manifest()}, &.{plugin.renderer()});
    defer host.deinit();
    context.inject(&host);
    var editor = model.Editor.init(a);
    defer editor.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const envelope = try editor.snapshot(arena.allocator());
    const first = try host.open(envelope, .{ .request_key = 11, .target = target });
    _ = try host.pollControllers();
    const runtime = plugin.runtimeFor(first.handle).?;
    try std.testing.expect(runtime.phase == .authenticating and !runtime.authenticated);
    try std.testing.expect(host.queryTypedService(first.handle, fixture.Lifecycle, fixture.lifecycle_key) == .temporarily_unavailable);
    try std.testing.expectError(error.ChallengeMismatch, context.challenge.submitAnswer(try first.handle.nextGeneration(), runtime.challenge_id, first.handle.generation + 1, .{ .secret_input = "stale" }, runtime.challenge_deadline - 1));
    try context.challenge.submitAnswer(first.handle, runtime.challenge_id, first.handle.generation, .{ .secret_input = "" }, runtime.challenge_deadline - 1);
    _ = try host.pollControllers();
    try std.testing.expect(runtime.phase == .closed and !runtime.authenticated);
    const second = try host.open(envelope, .{ .request_key = 12, .target = target });
    _ = try host.pollControllers();
    const cancelled = plugin.runtimeFor(second.handle).?;
    try std.testing.expect(try host.cancel(second.operation));
    try std.testing.expectError(error.ChallengeNotPending, context.challenge.submitAnswer(second.handle, cancelled.challenge_id, second.handle.generation, .{ .secret_input = "late" }, cancelled.challenge_deadline - 1));
    const third = try host.open(envelope, .{ .request_key = 13, .target = target });
    _ = try host.pollControllers();
    const expired = plugin.runtimeFor(third.handle).?;
    expired.challenge_deadline = 1;
    _ = try host.pollControllers();
    try std.testing.expect(expired.phase == .closed and !expired.authenticated);
    try std.testing.expectEqual(@as(usize, 3), plugin.releases);
}

const Driver = struct {
    opens: usize = 0,
    completions: usize = 0,
    gpu_updates: usize = 0,
    gpu_releases: usize = 0,
    fn open(ptr: *anyopaque, _: content.ChildRequest) !void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        self.opens += 1;
    }
    fn complete(ptr: *anyopaque, _: content.ChildCompletion) void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        self.completions += 1;
    }
    fn create(_: *anyopaque, _: u32, _: u32) !u32 {
        return 1;
    }
    fn update(ptr: *anyopaque, _: u32, rgba: []const u8) !void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        try std.testing.expectEqual(@as(usize, model.Frame.width * model.Frame.height * 4), rgba.len);
        self.gpu_updates += 1;
    }
    fn release(ptr: *anyopaque, _: u32) void {
        const self: *Driver = @ptrCast(@alignCast(ptr));
        self.gpu_releases += 1;
    }
    fn fullscreen(_: *anyopaque, _: bool) !void {}
    fn state(_: *anyopaque) bool {
        return false;
    }
    fn transfer(_: *anyopaque, _: identity.SessionHandle, _: identity.WindowId) !void {}
};
test "fixture consumes public nested editor and RGBA facades with stale result and frame gates" {
    var driver: Driver = .{};
    var editor_host: content.EditorHost = .{ .allocator = a, .context = &driver, .open_registered = Driver.open };
    defer editor_host.deinit();
    try editor_host.setParentRevision(11, 1);
    const request = try editor_host.openChild(11, 1, "ssh", .create);
    try editor_host.setParentRevision(11, 2);
    try std.testing.expect(!try editor_host.complete(request, .{ .saved = .{ .asset_id = @fromBackingInt(99), .revision = 1 } }, &driver, Driver.complete));
    const current = try editor_host.openChild(11, 2, "ssh", .create);
    try std.testing.expect(try editor_host.complete(current, .cancelled, &driver, Driver.complete));
    try std.testing.expectEqual(@as(usize, 2), driver.opens);
    try std.testing.expectEqual(@as(usize, 1), driver.completions);
    const owner: identity.SessionHandle = .{ .session_id = @fromBackingInt(1) };
    var sink = frames.Sink.init(owner, .{ .context = &driver, .create = Driver.create, .update = Driver.update, .release = Driver.release });
    var frame: model.Frame = .{};
    frame.render(true);
    try sink.submit(try frames.Frame.copy(a, owner, frame.revision, model.Frame.width, model.Frame.height, &frame.pixels));
    try std.testing.expect(try sink.drain());
    try sink.submit(try frames.Frame.copy(a, owner, frame.revision, model.Frame.width, model.Frame.height, &frame.pixels));
    try std.testing.expect(!try sink.drain());
    var stale = try frames.Frame.copy(a, try owner.nextGeneration(), 2, model.Frame.width, model.Frame.height, &frame.pixels);
    defer stale.deinit();
    try std.testing.expectError(error.StaleFrame, sink.submit(stale));
    try sink.close();
    try std.testing.expectEqual(@as(usize, 1), driver.gpu_updates);
    try std.testing.expectEqual(@as(usize, 1), driver.gpu_releases);
}

fn execute(table: *tools.RequestTable, parsed: tools.ParsedCall, live: scope.Scope, members: []const tools.Member, policy: tools.Policy, ticket: ?*tools.ApprovalTicket, now: i64, id: u64, arguments: []const u8) !tools.ToolResult {
    try tools.authorize(table, parsed, live, members, policy, ticket, now);
    const target_binding = parsed.entry.targets[0];
    return target_binding.binding.handler(target_binding.context, .{ .owner = target_binding.owner, .operation_id = id, .tool_id = parsed.entry.definition.id, .arguments = parsed.json.value, .arguments_json = arguments, .arguments_hash = parsed.arguments_hash }, a);
}
test "fixture observe is immutable PNG input changes canvas always_confirm refuses zero dispatch approves once" {
    var controller_context: ContextDriver = .{ .challenge = challenges.Host.init(a) };
    defer controller_context.challenge.deinit();
    const plugin = try fixture.Plugin.init(a);
    defer plugin.deinit();
    var host = try sessions.SessionHost.initPlugins(a, &.{plugin.manifest()}, &.{plugin.renderer()});
    defer host.deinit();
    controller_context.inject(&host);
    var editor = model.Editor.init(a);
    defer editor.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const accepted = try host.open(try editor.snapshot(arena.allocator()), .{ .request_key = 1, .target = target });
    try controller_context.ready(&host, plugin);
    const runtime = plugin.runtimeFor(accepted.handle).?;
    var driver: Driver = .{};
    var input: content.Context = .{ .owner = accepted.handle, .window_id = target.window_id, .window = .{ .context = &driver, .request_fullscreen = Driver.fullscreen, .fullscreen_state = Driver.state, .transfer = Driver.transfer }, .consumer = .{ .context = runtime, .consume = fixture.Runtime.consume } };
    defer input.close();
    try input.setAuthorization(true, 2);
    input.setFocus(true, false);
    runtime.input = &input;
    const captured: scope.Scope = .{ .owner = .{ .session = 1 }, .members = .{ .ids = .{1} ++ @as([15]u64, @splat(0)), .len = 1 } };
    var members = [_]tools.Member{.{ .owner = accepted.handle, .plugin_id = model.protocol_id, .context = plugin, .bindings = &fixture.tool_bindings, .services = &.{runtime.binding} }};
    var table = try tools.RequestTable.init(a, captured, &fixture.definitions, &members);
    defer table.deinit();
    const observe_args = "{\"session_ids\":[1]}";
    var observe = try table.parse(a, "fixture_uprobe__observe", observe_args);
    defer observe.deinit();
    var before = try execute(&table, observe, captured, &members, .{}, null, 0, 1, observe_args);
    defer before.deinit(a);
    const image = before.blocks[0].image_ref.content().?;
    try std.testing.expectEqual(@as(u32, model.Frame.width), image.width);
    try std.testing.expectEqualStrings("image/png", image.mime.name());
    const provider = @import("ai/provider.zig");
    const messages = [_]provider.Message{
        .{ .role = .user, .content = "Observe this synthetic workspace" },
        .{ .role = .assistant, .content = "", .tool_calls = &.{.{ .id = "fixture-observe-1", .name = "fixture_uprobe__observe", .arguments = observe_args }} },
        .{ .role = .tool, .content = "Synthetic canvas observation", .tool_call_id = "fixture-observe-1", .images = &.{before.blocks[0].image_ref} },
    };
    const provider_request: provider.ChatRequest = .{ .model = "gpt-4o", .system = "fixture", .messages = &messages, .vision = true, .tool_images = true };
    const body = try @import("ai/provider_http.zig").requestBody(a, .openai_compat, provider_request, 200_000);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/png;base64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fixture_probe:synthetic-canvas") == null);
    var no_image_capability = provider_request;
    no_image_capability.tool_images = false;
    try std.testing.expectError(error.ModelDoesNotSupportToolImages, @import("ai/provider_http.zig").requestBody(a, .openai_compat, no_image_capability, 200_000));
    const input_args = "{\"session_ids\":[1],\"kind\":\"pointer\",\"x\":30,\"y\":20}";
    var pointer = try table.parse(a, "fixture_uprobe__input", input_args);
    defer pointer.deinit();
    var input_result = try execute(&table, pointer, captured, &members, .{ .full_control = true }, null, 0, 2, input_args);
    defer input_result.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), runtime.input_events);
    const key_args = "{\"session_ids\":[1],\"kind\":\"key\",\"code\":65}";
    var key = try table.parse(a, "fixture_uprobe__input", key_args);
    defer key.deinit();
    var key_result = try execute(&table, key, captured, &members, .{ .full_control = true }, null, 0, 3, key_args);
    defer key_result.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), runtime.input_events);
    try std.testing.expectEqual(@as(u32, 1), runtime.frame.key_count);
    var after = try execute(&table, observe, captured, &members, .{}, null, 0, 3, observe_args);
    defer after.deinit(a);
    try std.testing.expect(!std.mem.eql(u8, &image.sha256, &after.blocks[0].image_ref.content().?.sha256));
    const write_args = "{\"session_ids\":[1],\"powered\":false}";
    var write = try table.parse(a, "fixture_uprobe__write", write_args);
    defer write.deinit();
    try std.testing.expectError(error.ToolApprovalRequired, execute(&table, write, captured, &members, .{ .full_control = true }, null, 0, 4, write_args));
    var approval = try tools.ApprovalTicket.create(&table, write, 0, 1000);
    try std.testing.expectError(error.ToolApprovalRequired, execute(&table, write, captured, &members, .{ .full_control = true }, &approval, 0, 4, write_args));
    approval.approve();
    try std.testing.expectError(error.ToolApprovalExpired, execute(&table, write, captured, &members, .{ .full_control = true }, &approval, 1000, 4, write_args));
    try std.testing.expectEqual(@as(usize, 0), runtime.write_events);
    const changed_args = "{\"session_ids\":[1],\"powered\":true}";
    var changed_write = try table.parse(a, "fixture_uprobe__write", changed_args);
    defer changed_write.deinit();
    try std.testing.expectError(error.ToolApprovalChanged, execute(&table, changed_write, captured, &members, .{ .full_control = true }, &approval, 1, 4, changed_args));
    try std.testing.expectEqual(@as(usize, 0), runtime.write_events);
    var result = try execute(&table, write, captured, &members, .{ .full_control = true }, &approval, 1, 4, write_args);
    defer result.deinit(a);
    try std.testing.expectError(error.ToolApprovalAlreadyUsed, execute(&table, write, captured, &members, .{ .full_control = true }, &approval, 1, 4, write_args));
    try std.testing.expectEqual(@as(usize, 1), runtime.write_events);
    const lease = input.automation.?;
    input.setFocus(true, true);
    const human = try input.acquire(.human_focus, input.authorization_revision);
    try std.testing.expectError(error.StaleInputLease, input.route(lease, 6, .{ .text = "old automation" }, false));
    try input.transferWindow(@fromBackingInt(2));
    try std.testing.expectError(error.StaleInputLease, input.route(human, 7, .{ .text = "old window" }, false));
    input.setFocus(false, false);
    try std.testing.expectError(error.StaleInputLease, input.route(lease, 8, .{ .text = "stale" }, false));
    try std.testing.expectEqual(@as(usize, 2), runtime.input_events);
    members[0].owner = try accepted.handle.nextGeneration();
    try std.testing.expectError(error.StaleToolAuthority, execute(&table, observe, captured, &members, .{}, null, 2, 5, observe_args));
    runtime.input = null;
}

test {
    _ = @import("ui/plugin_window_host.zig");
}
