//! One completion fact refreshes only its original, still-visible destination.
//! The existing directory controller owns requests, IO, revisions and selection.
const std = @import("std");
const transfer = @import("../transfer/manager.zig");
const identity = @import("identity.zig");
const files = @import("file_workspace_controller.zig");

pub const Target = struct {
    owner: identity.SessionHandle,
    endpoint: files.fs.EndpointRef,
    directory: []const u8,
};

pub const Completion = struct {
    const Key = struct { job: transfer.JobId, attempt: u8 };
    handled: ?Key = null,

    /// False may mean no applicable view or a newer navigation still in flight.
    /// No borrowed path or controller pointer survives this synchronous call.
    pub fn update(self: *Completion, progress: transfer.Progress, target: Target, current: ?*files.Controller) !bool {
        if (progress.state != .succeeded or progress.job_cleanup != .released) return false;
        if (self.handled) |previous| if (previous.job == progress.job and previous.attempt == progress.attempt) return false;
        const key: Key = .{ .job = progress.job, .attempt = progress.attempt };
        const model = current orelse {
            self.handled = key;
            return false;
        };
        if (model.closing or !model.options.owner.eql(target.owner) or !model.options.local.endpoint.eql(target.endpoint) or !model.options.local.service.endpoint.eql(target.endpoint)) {
            self.handled = key;
            return false;
        }
        const projection = model.projection() orelse return false;
        const pane = projection.panes[0];
        // Do not cancel/reorder a user's newer navigation. Re-evaluate the
        // resulting directory next tick; it may no longer be this destination.
        if (pane.state == .loading) return false;
        if (!projection.owner.eql(target.owner) or !pane.stamp.owner.eql(target.owner) or pane.stamp.endpoint.kind != .local_fs or pane.stamp.endpoint.binding_id != target.endpoint.binding_id or pane.stamp.endpoint.binding_generation != target.endpoint.binding_generation or !std.mem.eql(u8, pane.resolved_path, target.directory)) {
            self.handled = key;
            return false;
        }
        // A dispatch failure is reported once; it never changes the completed
        // transfer or fabricates updated directory metadata.
        self.handled = key;
        try model.handle(.{
            .side = .local,
            .stamp = pane.stamp,
            .projection_revision = projection.revision,
            .selection_revision = pane.selection_revision,
            .action = .refresh,
        });
        return true;
    }
};
