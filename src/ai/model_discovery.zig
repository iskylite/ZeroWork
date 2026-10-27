//! Background model discovery. All UI publication happens in poll(), never on workers.
const std = @import("std");
const config = @import("../config/config.zig");
const catalog = @import("model_catalog.zig");
const transport = @import("provider_transport.zig");
const http = @import("provider_http.zig");
pub const ModelMetadata = struct { id: []const u8, reasoning_known: bool, vision_known: bool };
pub const Service = struct {
    job: ?*Job = null,
    current: ?*Job = null,
    generation: u64 = 0,
    next_refresh: i64 = 0,
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
        if (self.job != null) return error.WorkerBusy;
        var selected = provider;
        selected.enabled = true;
        selected.models = &.{};
        selected.model_count = 0;
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
    /// now is monotonic seconds supplied by the host.
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
                job.destroy();
                self.next_refresh = @min(self.next_refresh, now + 300);
            }
        };
        if (self.job == null and (self.revision != revision or now >= self.next_refresh)) {
            const job = try Job.create(ai, revision);
            errdefer job.destroy();
            job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
            self.job = job;
            self.revision = revision;
            self.next_refresh = now + catalog.refresh_seconds;
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
        const t = transport.native(&context);
        const provider_config = @import("provider_config.zig");
        const resolved = try provider_config.fromSettings(self.ai);
        var plan = try http.plan(resolved);
        plan.endpoint = try http.chatEndpoint(self.arena.allocator(), resolved.kind, resolved.endpoint);
        plan.cancel = &self.cancel;
        plan.timeout_ms = 30000;
        const messages = [_]@import("provider.zig").Message{.{ .content = "Reply with OK." }};
        const body = try http.requestBody(self.arena.allocator(), resolved.kind, .{ .model = resolved.model, .system = "", .messages = &messages, .max_output = 32 }, resolved.context_window);
        _ = try self.fetch(t, plan, body);
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
        for (self.ai.providers) |*p| {
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
            var models: std.ArrayList(config.AiModel) = .empty;
            try models.appendSlice(a, p.models);
            if (remote) |r| for (r.entries) |entry| {
                var exists = false;
                for (models.items) |m| if (std.mem.eql(u8, m.id, entry.id)) {
                    exists = true;
                    break;
                };
                if (!exists) try models.append(a, .{ .id = try a.dupe(u8, entry.id), .context_window = entry.capability.context orelse if (self.require_list) 0 else if (p.context_window != 0) p.context_window else 8192, .efforts = @splat(false) });
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
                    const show_url = try std.fmt.allocPrint(a, "{s}/show", .{url[0 .. url.len - 5]});
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
