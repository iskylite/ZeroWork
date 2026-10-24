//! One challenge mailbox and presenter per Cx, shared by plugin controllers,
//! built-in connections, file opens and offline probes.
const ui = @import("ui");
const identity = @import("../host/identity.zig");
const challenge = @import("../host/challenge_host.zig");
const presenter = @import("plugin_challenge_presenter.zig");
pub const Services = struct {
    cx: *ui.Cx,
    host: challenge.Host,
    view: *presenter.Presenter = undefined,
    active_owner: ?identity.SessionHandle = null,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*Services {
        if (cx.consume(Services)) |existing| return existing;
        const self = try cx.bindState(Services, .{ .cx = cx, .host = challenge.Host.init(cx.allocator) });
        self.view = try presenter.Presenter.mount(cx, scope, &self.host);
        try cx.provide(Services, self);
        try cx.addAfterLayoutHook(self, frame);
        return self;
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Services = @ptrCast(@alignCast(raw));
        const ns = @import("../platform/realtime.zig").monotonicNs();
        self.host.tick(@intCast(@max(0, ns) / @import("std").time.ns_per_ms));
        self.view.update(self.active_owner) catch {};
        return .done;
    }
    pub fn deinit(self: *Services) void {
        self.cx.removeAfterLayoutHook(self);
        self.host.deinit();
    }
};
