//! Background model discovery. All UI publication happens in poll(), never on workers.
const std = @import("std");
const config = @import("../config/config.zig");
const catalog = @import("model_catalog.zig");
const transport = @import("provider_transport.zig");
const http = @import("provider_http.zig");
pub const list_refresh_seconds = 5 * 60;
fn initialContextWindow(p: config.AiProvider, advertised: ?u32, require_list: bool) u32 {
    // Missing metadata stays unknown; never invent an 8K model window.
    return advertised orelse if (require_list) 0 else p.context_window;
}
fn automaticList(p: config.AiProvider) bool {
    return p.model_count == 0 and p.model.len == 0;
}
fn hasAutomaticList(ai: config.Ai) bool {
    for (ai.providers[0..@min(ai.provider_count, ai.providers.len)]) |p| {
        if (p.enabled and p.endpoint.len != 0 and automaticList(p)) return true;
    }
    return false;
}
pub const ModelMetadata = struct { id: []const u8, reasoning_known: bool, vision_known: bool };
pub const Service = struct {
    job: ?*Job = null,
    current: ?*Job = null,
    generation: u64 = 0,
    next_refresh: i64 = 0,
    next_list_refresh: i64 = 0,
    list_refresh_requested: bool = false,
    revision: u64 = 0,
    request_error: ?anyerror = null,
    diagnostic: http.Diagnostic = .{},
    pub fn deinit(self: *Service) void {
        if (self.job) |job| {
            job.cancel.cancel();
            job.thread.?.join();
            job.destroy();
        }
        if (self.current) |current| current.destroy();
    }
    pub fn busy(self: *const Service) bool {
        return self.job != null;
    }
    pub fn effective(self: *const Service, ai: config.Ai, revision: u64) config.Ai {
        if (self.current) |current| if (current.revision == revision) return current.ai;
        return ai;
    }
    pub fn modelMetadata(self: *const Service, id: []const u8) ?ModelMetadata {
        const current = self.current orelse return null;
        for (current.metadata.items) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
    /// Explicit settings discovery uses the same transport/parser without saving
    /// candidates into the configuration. Disabled drafts may be inspected.
    pub fn request(self: *Service, provider: config.AiProvider, revision: u64) !void {
        try @import("../update/admission.zig").require();
        if (self.job != null) return error.WorkerBusy;
        var selected = provider;
        selected.enabled = true;
        selected.models = &.{};
        selected.model_count = 0;
        selected.model = "";
        const job = try Job.create(.{ .providers = @constCast(&[_]config.AiProvider{selected}), .provider_count = 1 }, revision);
        errdefer job.destroy();
        job.require_list = true;
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.request_error = null;
        self.job = job;
    }
    pub fn testModel(self: *Service, provider: config.AiProvider, model: config.AiModel) !void {
        if (self.job != null) return error.WorkerBusy;
        var selected = provider;
        var selected_model = model;
        selected_model.default = true;
        selected.enabled = true;
        selected.models = @constCast(&[_]config.AiModel{selected_model});
        selected.model_count = 1;
        const job = try Job.create(.{ .default_provider = @import("provider_config.zig").providerId(selected), .providers = @constCast(&[_]config.AiProvider{selected}), .provider_count = 1 }, 0);
        errdefer job.destroy();
        job.probe = true;
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.request_error = null;
        self.job = job;
    }
    pub fn cancelRequest(self: *Service) void {
        if (self.job) |job| job.cancel.cancel();
    }
    /// Publishes completed worker memory only on the UI thread.
    pub fn finishRequest(self: *Service) bool {
        const job = self.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        job.thread.?.join();
        self.job = null;
        self.request_error = job.failure;
        self.diagnostic = job.diagnostic;
        if (job.success) {
            if (self.current) |old| old.destroy();
            self.current = job;
            self.generation +|= 1;
        } else job.destroy();
        return true;
    }
    /// Opening the picker only queues work; poll starts it at the UI safe point.
    /// An in-flight discovery already supplies a fresh list, so openings coalesce.
    pub fn refreshLists(self: *Service) void {
        if (self.job == null) self.list_refresh_requested = true;
    }
    pub fn refreshDelaySeconds(self: *const Service, ai: config.Ai, now: i64) u64 {
        const due = if (hasAutomaticList(ai)) @min(self.next_refresh, self.next_list_refresh) else self.next_refresh;
        return @intCast(@max(1, due - now));
    }
    /// now is seconds supplied by the host.
    pub fn poll(self: *Service, ai: config.Ai, revision: u64, now: i64) !bool {
        var changed = false;
        if (self.job) |job| if (job.done.load(.acquire)) {
            job.thread.?.join();
            self.job = null;
            if (job.revision == revision and job.success) {
                if (self.current) |current| current.destroy();
                self.current = job;
                self.generation +|= 1;
                changed = true;
            } else {
                const only_lists = job.only_automatic_lists;
                job.destroy();
                if (only_lists) self.next_list_refresh = @min(self.next_list_refresh, now + list_refresh_seconds) else self.next_refresh = @min(self.next_refresh, now + 300);
            }
        };
        if (self.job == null) {
            const full_refresh = self.revision != revision or now >= self.next_refresh;
            const list_refresh = hasAutomaticList(ai) and (self.list_refresh_requested or now >= self.next_list_refresh);
            self.list_refresh_requested = false;
            if (full_refresh or list_refresh) {
                const job = try Job.createRefresh(ai, self.effective(ai, revision), revision, !full_refresh);
                errdefer job.destroy();
                job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
                self.job = job;
                self.revision = revision;
                if (full_refresh) self.next_refresh = now + catalog.refresh_seconds;
                self.next_list_refresh = now + list_refresh_seconds;
            }
        }
        return changed;
    }
};
const Job = struct {
    arena: std.heap.ArenaAllocator,
    ai: config.Ai,
    revision: u64,
    thread: ?std.Thread = null,
    cancel: @import("provider.zig").CancelToken = .{},
    done: std.atomic.Value(bool) = .init(false),
    success: bool = false,
    require_list: bool = false,
    only_automatic_lists: bool = false,
    automatic_lists: []const bool = &.{},
    probe: bool = false,
    failure: ?anyerror = null,
    diagnostic: http.Diagnostic = .{},
    metadata: std.ArrayList(ModelMetadata) = .empty,
    fn create(ai: config.Ai, revision: u64) !*Job {
        const self = try std.heap.c_allocator.create(Job);
        self.* = .{ .arena = .init(std.heap.c_allocator), .ai = ai, .revision = revision };
        errdefer self.destroy();
        const a = self.arena.allocator();
        self.ai.default_provider = try a.dupe(u8, ai.default_provider);
        self.ai.providers = try a.dupe(config.AiProvider, ai.providers[0..@min(ai.provider_count, ai.providers.len)]);
        self.ai.provider_count = self.ai.providers.len;
        for (self.ai.providers) |*p| {
            p.name = try a.dupe(u8, p.name);
            p.endpoint = try a.dupe(u8, p.endpoint);
            p.api_key = try a.dupe(u8, p.api_key);
            p.model = try a.dupe(u8, p.model);
            p.models = try a.dupe(config.AiModel, p.models[0..@min(p.model_count, p.models.len)]);
            for (p.models) |*m| m.id = try a.dupe(u8, m.id);
        }
        return self;
    }
    fn createRefresh(source: config.Ai, previous: config.Ai, revision: u64, only_automatic_lists: bool) !*Job {
        const job = try Job.create(if (only_automatic_lists) previous else source, revision);
        errdefer job.destroy();
        const automatic = try job.arena.allocator().alloc(bool, job.ai.provider_count);
        for (automatic, source.providers[0..job.ai.provider_count]) |*value, p| value.* = automaticList(p);
        job.automatic_lists = automatic;
        job.only_automatic_lists = only_automatic_lists;
        return job;
    }
    fn destroy(self: *Job) void {
        self.arena.deinit();
        std.heap.c_allocator.destroy(self);
    }
    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        const result = if (self.probe) self.testChat() else self.discover();
        result catch |err| {
            self.failure = err;
            self.success = false;
            return;
        };
        // discover publishes success only after at least one valid source.
    }
    fn fetch(self: *Job, t: transport.Transport, plan: http.RequestPlan, body: []const u8) ![]u8 {
        if (!std.mem.startsWith(u8, plan.endpoint, "https://") and !http.isLoopbackHttp(plan.endpoint)) return error.InsecureEndpoint;
        const native_context: *transport.NativeContext = @ptrCast(@alignCast(t.ctx));
        var response = t.send(t.ctx, plan, body, self.arena.allocator()) catch |err| {
            self.diagnostic = native_context.diagnostic;
            return err;
        };
        self.diagnostic = native_context.diagnostic;
        defer response.deinit(self.arena.allocator());
        if (response.status < 200 or response.status >= 300) return error.ModelDiscoveryFailed;
        return self.arena.allocator().dupe(u8, response.body);
    }
    fn testChat(self: *Job) !void {
        var io: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer io.deinit();
        var context: transport.NativeContext = .{ .io = io.io() };
        defer if (context.diagnostic.status != 0) {
            self.diagnostic = context.diagnostic;
        };
        const t = transport.native(&context);
        const provider_config = @import("provider_config.zig");
        const resolved = try provider_config.fromSettings(self.ai);
        try probeChat(self.arena.allocator(), t, resolved, &self.cancel, &self.diagnostic);
        self.success = true;
    }
    fn discover(self: *Job) !void {
        var io: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer io.deinit();
        var context: transport.NativeContext = .{ .io = io.io() };
        const t = transport.native(&context);
        const a = self.arena.allocator();
        var fallback: ?catalog.Catalog = null;
        defer if (fallback) |*c| c.deinit();
        var fallback_attempted = false;
        for (self.ai.providers, 0..) |*p, provider_index| {
            if (self.only_automatic_lists and !self.automatic_lists[provider_index]) continue;
            if (self.cancel.isCancelled()) return error.Cancelled;
            if (!p.enabled or p.endpoint.len == 0) continue;
            const url = try catalog.endpoint(a, p.endpoint, p.kind);
            const auth: http.AuthStyle = if (p.api_key.len == 0) .none else if (p.kind == .anthropic) .anthropic_key else .bearer;
            const plan: http.RequestPlan = .{ .method = .GET, .endpoint = url, .accept = "application/json", .auth_style = auth, .api_key = if (p.api_key.len == 0) null else p.api_key, .timeout_ms = 10000, .cancel = &self.cancel };
            const body = self.fetch(t, plan, "") catch |err| if (self.require_list) return err else null;
            var remote: ?catalog.Catalog = if (body) |bytes| catalog.Catalog.parse(std.heap.c_allocator, bytes, if (p.kind == .ollama) .ollama else .endpoint) catch null else null;
            if (self.require_list and remote == null) return error.InvalidCatalog;
            if (p.kind == .anthropic and remote != null and body != null) {
                var page_body = body.?;
                var last_cursor: []const u8 = "";
                for (0..49) |_| {
                    const parsed = try std.json.parseFromSlice(std.json.Value, a, page_body, .{});
                    const more = catalog.field(parsed.value, "has_more") orelse break;
                    if (more != .bool or !more.bool) break;
                    const cursor = catalog.field(parsed.value, "last_id") orelse break;
                    if (cursor != .string or cursor.string.len == 0 or cursor.string.len > 512 or std.mem.eql(u8, cursor.string, last_cursor)) break;
                    last_cursor = cursor.string;
                    const escaped = try escapeCursor(a, cursor.string);
                    var next_plan = plan;
                    next_plan.endpoint = try std.fmt.allocPrint(a, "{s}{s}limit=1000&after_id={s}", .{ url, if (std.mem.indexOfScalar(u8, url, '?') == null) "?" else "&", escaped });
                    page_body = self.fetch(t, next_plan, "") catch break;
                    var page = catalog.Catalog.parse(std.heap.c_allocator, page_body, .endpoint) catch break;
                    defer page.deinit();
                    const ra = remote.?.arena.allocator();
                    const previous = remote.?.entries;
                    if (previous.len + page.entries.len > 50000) return error.CatalogTooLarge;
                    const all = try ra.alloc(catalog.Entry, previous.len + page.entries.len);
                    @memcpy(all[0..previous.len], previous);
                    for (page.entries, all[previous.len..]) |entry, *dst| {
                        dst.* = entry;
                        dst.id = try ra.dupe(u8, entry.id);
                        dst.provider = try ra.dupe(u8, entry.provider);
                        dst.api = try ra.dupe(u8, entry.api);
                    }
                    remote.?.entries = all;
                }
            }
            if (remote != null) self.success = true;
            defer if (remote) |*c| c.deinit();
            if (self.only_automatic_lists and remote == null) continue;
            var models: std.ArrayList(config.AiModel) = .empty;
            // A short refresh starts from the published snapshot. Replace an
            // automatic list only on a valid response; failures keep its old list.
            const replace_list = self.only_automatic_lists and remote != null;
            if (!replace_list) try models.appendSlice(a, p.models);
            if (models.items.len == 0 and p.model.len != 0) try models.append(a, .{ .id = p.model, .context_window = p.context_window, .default = true, .efforts = @splat(false) });
            // A configured list is authoritative. Only an unconfigured provider
            // adopts the remote list; both paths still receive capability metadata.
            if (models.items.len == 0) if (remote) |r| for (r.entries) |entry| {
                var exists = false;
                for (models.items) |m| if (std.mem.eql(u8, m.id, entry.id)) {
                    exists = true;
                    break;
                };
                if (!exists) try models.append(a, .{ .id = try a.dupe(u8, entry.id), .context_window = initialContextWindow(p.*, entry.capability.context, self.require_list), .efforts = @splat(false) });
            };
            var provider_id = if (p.name.len != 0) p.name else @tagName(p.kind);
            if (fallback) |f| for (f.entries) |entry| {
                if (entry.api.len != 0 and sameHost(entry.api, p.endpoint)) {
                    provider_id = entry.provider;
                    break;
                }
            };
            for (models.items) |*m| {
                var capability: catalog.Capability = .{};
                if (remote) |r| capability = r.resolve("", m.id) orelse .{};
                if (p.kind == .ollama) {
                    const show_url = try @import("provider_endpoint.zig").ollamaShowEndpoint(a, p.endpoint);
                    const show_body = try std.json.Stringify.valueAlloc(a, .{ .model = m.id }, .{});
                    var show_plan = plan;
                    show_plan.method = .POST;
                    show_plan.endpoint = show_url;
                    if (self.fetch(t, show_plan, show_body)) |bytes| {
                        const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch null;
                        if (parsed) |v| {
                            capability = catalog.metadata(v.value);
                        }
                    } else |_| {}
                }
                // Missing capability metadata is resolved independently of list availability.
                if (!self.require_list and !fallback_attempted and (capability.reasoning == null or !capability.control_known or capability.context == null or capability.vision == null)) {
                    fallback_attempted = true;
                    const public_plan: http.RequestPlan = .{ .method = .GET, .endpoint = "https://models.dev/api.json", .accept = "application/json", .auth_style = .none, .timeout_ms = 10000, .cancel = &self.cancel };
                    if (self.fetch(t, public_plan, "")) |bytes| {
                        fallback = catalog.Catalog.parse(std.heap.c_allocator, bytes, .models_dev) catch null;
                        if (fallback != null) self.success = true;
                    } else |_| {}
                }
                if (fallback) |f| for (f.entries) |entry| {
                    if (entry.api.len != 0 and sameHost(entry.api, p.endpoint)) {
                        provider_id = entry.provider;
                        break;
                    }
                };
                const supplement = if (fallback) |f| f.resolve(provider_id, m.id) else null;
                if (capability.reasoning == null) if (supplement) |c| {
                    capability.reasoning = c.reasoning;
                };
                if (!capability.control_known) if (supplement) |c| {
                    capability.toggle = c.toggle;
                    capability.efforts = c.efforts;
                    capability.control_known = c.control_known;
                };
                if (capability.context == null) if (supplement) |c| {
                    capability.context = c.context;
                };
                if (capability.vision == null) if (supplement) |c| {
                    capability.vision = c.vision;
                };
                if (self.require_list) try self.metadata.append(a, .{ .id = m.id, .reasoning_known = capability.reasoning != null, .vision_known = capability.vision != null });
                if (capability.reasoning) |v| m.reasoning = v;
                if (capability.context) |v| {
                    m.context_window = v;
                    m.context_discovered = true;
                }
                if (capability.vision) |v| m.vision = v;
                if (capability.control_known) {
                    m.reasoning_discovered = true;
                    m.reasoning_adaptive = capability.adaptive;
                    m.thinking_default = capability.thinking_default orelse if (@import("provider_config.zig").toggleProtocol(p.kind, p.endpoint, m.id) == .thinking_type) true else null;
                    m.reasoning_toggle = capability.toggle;
                    m.efforts = capability.efforts;
                }
            }
            p.models = try models.toOwnedSlice(a);
            p.model_count = p.models.len;
        }
    }
};

test "model discovery preserves configured models and discovers all only when unconfigured" {
    const Fixture = struct {
        io: std.Io,
        server: std.Io.net.Server,
        fn serve(self: *@This()) !void {
            const connection = try self.server.accept(self.io);
            defer connection.close(self.io);
            var buffer: [4096]u8 = undefined;
            var reader = connection.reader(self.io, &buffer);
            const request_line = try reader.interface.takeDelimiterInclusive('\n');
            try std.testing.expectEqualStrings("GET /proxy/models HTTP/1.1\r\n", request_line);
            while (true) {
                const line = try reader.interface.takeDelimiterInclusive('\n');
                if (std.mem.eql(u8, line, "\r\n")) break;
            }
            // Full metadata keeps this regression entirely on loopback.
            const payload =
                \\{"data":[{"id":"other","context_window":32768,"reasoning":false,"vision":false},{"id":"chosen","context_window":131072,"reasoning":true,"reasoning_levels":["low"],"vision":true},{"id":"other","context_window":32768,"reasoning":false,"vision":false}]}
            ;
            var writer = connection.writer(self.io, &.{});
            try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ payload.len, payload });
            try writer.interface.flush();
        }
    };
    for ([_]struct { count: usize, legacy: bool = false, expected: []const []const u8 }{
        .{ .count = 1, .expected = &.{"chosen"} },
        .{ .count = 2, .expected = &.{ "chosen", "other" } },
        .{ .count = 0, .expected = &.{ "other", "chosen" } },
        .{ .count = 0, .legacy = true, .expected = &.{"chosen"} },
    }) |case| {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var fixture: Fixture = .{ .io = std.testing.io, .server = try address.listen(std.testing.io, .{}) };
        defer fixture.server.deinit(std.testing.io);
        var serving = try std.Io.concurrent(std.testing.io, Fixture.serve, .{&fixture});
        defer _ = serving.cancel(std.testing.io) catch {};
        var endpoint_buffer: [128]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/proxy", .{fixture.server.socket.address.getPort()});
        var configured = [_]config.AiModel{
            .{ .id = "chosen", .context_window = 8192, .default = true },
            .{ .id = "other", .context_window = 8192 },
        };
        var providers = [_]config.AiProvider{.{ .name = "gateway", .kind = .openai_compat, .enabled = true, .endpoint = endpoint, .api_key = "fixture-key", .models = &configured, .model_count = case.count, .model = if (case.legacy) "chosen" else "", .context_window = 8192 }};
        const source: config.Ai = .{ .default_provider = "gateway", .providers = &providers, .provider_count = 1 };
        var service: Service = .{};
        defer service.deinit();
        const job = try Job.create(source, 7);
        service.current = job;
        try job.discover();
        try serving.await(std.testing.io);
        try std.testing.expect(job.success);
        const effective = service.effective(source, 7);
        const actual = effective.providers[0];
        try std.testing.expectEqual(case.expected.len, actual.model_count);
        for (case.expected, actual.models) |expected, model| try std.testing.expectEqualStrings(expected, model.id);
        const selection = @import("provider_config.zig");
        const chosen = try selection.fromSettingsSelection(effective, .{ .provider_id = "gateway", .model_id = "chosen" });
        try std.testing.expectEqual(@as(u32, 131072), chosen.context_window);
        try std.testing.expect(chosen.vision);
        for (actual.models) |model| if (std.mem.eql(u8, model.id, "chosen")) {
            try std.testing.expect(model.reasoning and model.efforts[0]);
            if (case.expected.len == 1) try std.testing.expect(model.default);
        };
        if (case.expected.len == 1) {
            try std.testing.expectError(error.UnknownModel, selection.fromSettingsSelection(effective, .{ .provider_id = "gateway", .model_id = "other" }));
        } else _ = try selection.fromSettingsSelection(effective, .{ .provider_id = "gateway", .model_id = "other" });
        // Discovery is runtime-only and cannot rewrite the user's saved list.
        try std.testing.expectEqual(case.count, source.providers[0].model_count);
        try std.testing.expectEqual(@as(u32, 8192), configured[0].context_window);
        const stale = service.effective(source, 8);
        try std.testing.expectEqual(case.count, stale.providers[0].model_count);
    }
}

test "model discovery refreshes automatic lists in five minutes and on picker open" {
    const Fixture = struct {
        io: std.Io,
        server: std.Io.net.Server,
        fn serve(self: *@This()) !void {
            for (0..6) |index| {
                const connection = try self.server.accept(self.io);
                defer connection.close(self.io);
                var buffer: [4096]u8 = undefined;
                var reader = connection.reader(self.io, &buffer);
                _ = try reader.interface.takeDelimiterInclusive('\n');
                const payload = switch (index) {
                    0, 3 => "{\"data\":[{\"id\":\"old\",\"context_window\":64000,\"reasoning\":false,\"vision\":false}]}",
                    1 => "{\"data\":[{\"id\":\"manual\",\"context_window\":128000,\"reasoning\":false,\"vision\":false}]}",
                    2 => "{\"data\":[{\"id\":\"new\",\"context_window\":64000,\"reasoning\":false,\"vision\":false}]}",
                    else => "{\"data\":[]}",
                };
                var writer = connection.writer(self.io, &.{});
                try writer.interface.print("HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ if (index == 4) "503 Unavailable" else "200 OK", payload.len, payload });
                try writer.interface.flush();
            }
        }
        fn finish(service: *Service, source: config.Ai, now: i64) !bool {
            for (0..10000) |_| {
                if (service.job.?.done.load(.acquire)) return service.poll(source, 7, now);
                var unused: [0]std.c.pollfd = .{};
                _ = std.c.poll(&unused, 0, 1);
            }
            return error.DiscoveryTimeout;
        }
    };
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var fixture: Fixture = .{ .io = std.testing.io, .server = try address.listen(std.testing.io, .{}) };
    defer fixture.server.deinit(std.testing.io);
    var serving = try std.Io.concurrent(std.testing.io, Fixture.serve, .{&fixture});
    defer _ = serving.cancel(std.testing.io) catch {};
    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "http://127.0.0.1:{d}/v1", .{fixture.server.socket.address.getPort()});
    var manual = [_]config.AiModel{.{ .id = "manual", .context_window = 8192 }};
    var providers = [_]config.AiProvider{
        .{ .name = "automatic", .enabled = true, .endpoint = endpoint },
        .{ .name = "configured", .enabled = true, .endpoint = endpoint, .models = &manual, .model_count = 1 },
    };
    const source: config.Ai = .{ .providers = &providers, .provider_count = providers.len };
    var service: Service = .{};
    defer service.deinit();
    try std.testing.expect(!try service.poll(source, 7, 1000));
    service.refreshLists(); // Opening during an in-flight request must not queue another.
    try std.testing.expect(!service.list_refresh_requested);
    try std.testing.expect(try Fixture.finish(&service, source, 1000));
    try std.testing.expectEqual(@as(i64, 1300), service.next_list_refresh);
    try std.testing.expectEqual(@as(u64, 300), service.refreshDelaySeconds(source, 1000));
    try std.testing.expectEqualStrings("old", service.effective(source, 7).providers[0].models[0].id);
    try std.testing.expect(!try service.poll(source, 7, 1299));
    try std.testing.expect(!service.busy());
    try std.testing.expect(!try service.poll(source, 7, 1300));
    try std.testing.expect(service.job.?.only_automatic_lists);
    try std.testing.expect(try Fixture.finish(&service, source, 1300));
    try std.testing.expectEqualStrings("new", service.effective(source, 7).providers[0].models[0].id);
    // The configured provider retains discovered metadata without another request.
    try std.testing.expectEqual(@as(u32, 128000), service.effective(source, 7).providers[1].models[0].context_window);
    try std.testing.expectEqual(@as(i64, 1000 + catalog.refresh_seconds), service.next_refresh);
    service.refreshLists();
    try std.testing.expect(!try service.poll(source, 7, 1301));
    try std.testing.expect(try Fixture.finish(&service, source, 1301));
    try std.testing.expectEqualStrings("old", service.effective(source, 7).providers[0].models[0].id);
    service.refreshLists();
    try std.testing.expect(!try service.poll(source, 7, 1302));
    try std.testing.expect(!try Fixture.finish(&service, source, 1302));
    try std.testing.expectEqualStrings("old", service.effective(source, 7).providers[0].models[0].id);
    service.refreshLists();
    try std.testing.expect(!try service.poll(source, 7, 1303));
    try std.testing.expect(try Fixture.finish(&service, source, 1303));
    try std.testing.expectEqual(@as(usize, 0), service.effective(source, 7).providers[0].model_count);
    try serving.await(std.testing.io);
    // With only a configured provider, opening the picker keeps the daily cadence.
    const configured: config.Ai = .{ .providers = providers[1..], .provider_count = 1 };
    var configured_service: Service = .{ .revision = 7, .next_refresh = 87400 };
    defer configured_service.deinit();
    configured_service.refreshLists();
    try std.testing.expect(!try configured_service.poll(configured, 7, 1304));
    try std.testing.expect(!configured_service.busy());
    try std.testing.expectEqual(@as(u64, 86096), configured_service.refreshDelaySeconds(configured, 1304));
}

/// Use the production request path and protocol decoder, but require a real
/// completed answer before reporting a successful settings test.
fn probeChat(a: std.mem.Allocator, t: transport.Transport, resolved: @import("provider_config.zig").ProviderConfig, cancel: ?*@import("provider.zig").CancelToken, diagnostic: *http.Diagnostic) !void {
    const provider = @import("provider.zig");
    const json = @import("provider_json.zig");
    const Probe = struct {
        diagnostic: *http.Diagnostic,
        key: ?[]const u8,
        content: bool = false,
        done: bool = false,
        failed: bool = false,
        fn receive(raw: *anyopaque, delta: provider.Delta) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (delta) {
                .text, .thinking => |text| self.content = self.content or text.len != 0,
                .tool_plan => self.content = true,
                .done => self.done = true,
                .err => |message| {
                    self.failed = true;
                    self.diagnostic.captureMessage(200, message, self.key);
                },
            }
        }
        fn chunk(raw: *anyopaque, bytes: []const u8) !void {
            const stream: *json.Stream = @ptrCast(@alignCast(raw));
            try stream.feed(bytes);
        }
    };
    const key: ?[]const u8 = switch (resolved.auth) {
        .bearer_memory, .anthropic_memory => |value| value,
        .none => null,
    };
    var probe: Probe = .{ .diagnostic = diagnostic, .key = key };
    const kind: json.StreamKind = switch (resolved.kind) {
        .openai_compat => .openai_compat,
        .anthropic => .anthropic,
        .ollama => .ollama,
    };
    var stream = json.Stream.initWithKind(a, kind, Probe.receive, &probe);
    defer stream.deinit();
    const messages = [_]provider.Message{.{ .content = "Reply with OK." }};
    _ = try transport.requestStream(a, t, resolved, .{ .model = resolved.model, .system = "", .messages = &messages, .max_output = 32, .timeout_ms = 30000, .cancel = cancel }, Probe.chunk, &stream);
    try stream.finish();
    if (probe.failed or !probe.done or !probe.content) {
        if (diagnostic.status == 0) diagnostic.captureMessage(200, "", key);
        return error.InvalidModelResponse;
    }
}

test "model probe validates completed protocol responses instead of HTTP success" {
    const Mock = struct {
        body: []const u8,
        status: u16 = 200,
        calls: usize = 0,
        fn send(raw: *anyopaque, plan: http.RequestPlan, body: []const u8, a: std.mem.Allocator) !transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            try std.testing.expectEqual(std.http.Method.POST, plan.method);
            try std.testing.expect(std.mem.endsWith(u8, plan.endpoint, switch (plan.auth_style) {
                .bearer => "/api/gw/v1/chat/completions",
                .anthropic_key => "/api/gw/v1/messages",
                .none => "/api/gw/api/chat",
            }));
            try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
            return .{ .status = self.status, .body = try a.dupe(u8, self.body) };
        }
    };
    const openai_ok = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata: [DONE]\n\n";
    for ([_]struct { kind: @import("registry.zig").Kind = .openai_compat, body: []const u8, status: u16 = 200, failure: ?anyerror = null }{
        .{ .body = openai_ok },
        .{ .body = "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\n" },
        .{ .kind = .anthropic, .body = "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"OK\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n" },
        .{ .kind = .ollama, .body = "{\"message\":{\"content\":\"OK\"},\"done\":true}\n" },
        .{ .body = "", .failure = error.InvalidModelResponse },
        .{ .body = "{}", .failure = error.InvalidModelResponse },
        .{ .body = "data: [DONE]\n\n", .failure = error.InvalidModelResponse },
        .{ .body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n", .failure = error.InvalidModelResponse },
        .{ .body = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n", .failure = error.InvalidModelResponse },
        .{ .body = "data: {bad-json}\n\n", .failure = error.InvalidModelResponse },
        .{ .body = "data: {\"error\":{\"message\":\"fixture-key rejected\"}}\n\n", .failure = error.InvalidModelResponse },
        .{ .body = "<!DOCTYPE html><html>management</html>", .failure = error.HtmlResponse },
        .{ .body = "{}", .status = 403, .failure = error.ProviderFailure },
        .{ .kind = .ollama, .body = "{\"message\":{\"content\":\"partial\"},\"done\":false}\n", .failure = error.InvalidModelResponse },
    }) |item| {
        var mock: Mock = .{ .body = item.body, .status = item.status };
        var resolved = @import("provider_config.zig").defaults(item.kind);
        resolved.endpoint = if (item.kind == .ollama) "http://localhost/api/gw/api" else "https://gateway.test/api/gw/v1";
        resolved.auth = switch (item.kind) {
            .openai_compat => .{ .bearer_memory = "fixture-key" },
            .anthropic => .{ .anthropic_memory = "fixture-key" },
            .ollama => .none,
        };
        var diagnostic: http.Diagnostic = .{};
        const result = probeChat(std.testing.allocator, .{ .ctx = &mock, .send = Mock.send }, resolved, null, &diagnostic);
        if (item.failure) |err| try std.testing.expectError(err, result) else try result;
        try std.testing.expectEqual(@as(usize, 1), mock.calls);
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.message[0..diagnostic.len], "fixture-key") == null);
    }
    var mock: Mock = .{ .body = openai_ok };
    var cancel: @import("provider.zig").CancelToken = .{};
    cancel.cancel();
    var diagnostic: http.Diagnostic = .{};
    try std.testing.expectError(error.Cancelled, probeChat(std.testing.allocator, .{ .ctx = &mock, .send = Mock.send }, @import("provider_config.zig").defaults(.openai_compat), &cancel, &diagnostic));
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
}
fn sameHost(a: []const u8, b: []const u8) bool {
    const aa = std.Uri.parse(a) catch return false;
    const bb = std.Uri.parse(b) catch return false;
    const ah = aa.host orelse return false;
    const bh = bb.host orelse return false;
    return std.ascii.eqlIgnoreCase(switch (ah) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    }, switch (bh) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    });
}

fn escapeCursor(a: std.mem.Allocator, value: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') try result.append(a, byte) else {
            try result.append(a, '%');
            try result.append(a, "0123456789ABCDEF"[byte >> 4]);
            try result.append(a, "0123456789ABCDEF"[byte & 15]);
        }
    }
    return result.toOwnedSlice(a);
}

test "model discovery missing window stays unknown while explicit and advertised windows remain usable" {
    const selection = @import("provider_config.zig");
    for ([_]struct { configured: u32, advertised: ?u32 = null, require_list: bool = false, expected: u32 }{
        .{ .configured = 0, .expected = 0 },
        .{ .configured = 8192, .expected = 8192 },
        .{ .configured = 64000, .expected = 64000 },
        .{ .configured = 8192, .advertised = 131072, .expected = 131072 },
        .{ .configured = 8192, .require_list = true, .expected = 0 },
    }) |case| {
        var models = [_]config.AiModel{.{ .id = "unknown-fixture", .context_window = initialContextWindow(.{ .context_window = case.configured }, case.advertised, case.require_list) }};
        var providers = [_]config.AiProvider{.{ .name = "fixture", .enabled = true, .endpoint = "http://127.0.0.1:1/v1", .models = &models, .model_count = 1 }};
        const ai: config.Ai = .{ .providers = &providers, .provider_count = 1, .default_provider = "fixture" };
        try std.testing.expectEqual(case.expected, models[0].context_window);
        if (case.expected == 0) {
            try std.testing.expectError(error.InvalidContextWindow, selection.fromSettings(ai));
        } else {
            const selected = try selection.fromSettings(ai);
            try std.testing.expectEqual(case.expected, selected.context_window);
        }
    }
}
