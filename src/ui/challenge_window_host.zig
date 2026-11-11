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
    workspace: ?*@import("workspace.zig").Workspace = null,
    probe_owner: ?presenter.OwnerResolver = null,
    unattached_owner: ?presenter.OwnerResolver = null,
    pub fn mount(cx: *ui.Cx, scope: *ui.Scope) !*Services {
        if (cx.consume(Services)) |existing| return existing;
        const self = try cx.bindState(Services, .{ .cx = cx, .host = challenge.Host.init(cx.allocator) });
        self.view = try presenter.Presenter.mountWithOwner(cx, scope, &self.host, .{ .context = self, .get = resolveOwner });
        try cx.provide(Services, self);
        try cx.addAfterLayoutHook(self, frame);
        return self;
    }
    pub fn bindSessionOwner(self: *Services, workspace: *@import("workspace.zig").Workspace) void {
        self.workspace = workspace;
    }
    pub fn bindProbeOwner(self: *Services, owner: presenter.OwnerResolver) void {
        self.probe_owner = owner;
    }
    pub fn clearProbeOwner(self: *Services, context: *anyopaque) void {
        if (self.probe_owner) |owner| if (owner.context == context) {
            self.probe_owner = null;
        };
    }
    fn resolveOwner(raw: *anyopaque, owner: challenge.Owner) ?*ui.Node {
        const self: *Services = @ptrCast(@alignCast(raw));
        if (self.workspace == null and self.probe_owner == null) return self.cx.root;
        const session = switch (owner) {
            .session => |value| value,
            .operation => |operation| switch (operation.owner) {
                .session => |value| value,
                else => {
                    const probe = self.probe_owner orelse return null;
                    return probe.get(probe.context, owner);
                },
            },
        };
        const workspace = self.workspace orelse return null;
        if (workspace.overlayOwner(session)) |node| return node;
        if (self.probe_owner) |probe| if (probe.get(probe.context, owner)) |node| return node;
        const unattached = self.unattached_owner orelse return null;
        return unattached.get(unattached.context, owner);
    }
    fn frame(raw: *anyopaque, _: u8, _: bool) ui.AfterLayoutResult {
        const self: *Services = @ptrCast(@alignCast(raw));
        const ns = @import("../platform/realtime.zig").monotonicNs();
        self.host.tick(@intCast(@max(0, ns) / @import("std").time.ns_per_ms));
        const revision = self.view.projection_revision;
        self.view.update(self.active_owner) catch {};
        return if (self.view.projection_revision == revision) .done else .needs_layout;
    }
    pub fn deinit(self: *Services) void {
        self.cx.removeAfterLayoutHook(self);
        self.host.deinit();
    }
};
