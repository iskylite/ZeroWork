//! The renderer/AI boundary. This module contains no controller, driver,
//! transport, credentials or token access. Every snapshot owns its strings.
const std = @import("std");
const typed = @import("../../host/plugin_services.zig");
const identity = @import("../../host/identity.zig");
const operations = @import("../../host/operation.zig");
const services = @import("services.zig");
pub const remote_input = @import("remote_input.zig");
pub const framebuffer = @import("framebuffer.zig");
pub const progress = @import("connection_progress.zig");
pub const key: typed.ServiceKey = .{ .name = "bmc_ikvm.console", .major = 1 };
pub const RouteState = enum { frozen, connecting, connected, failed, closed };
pub const VideoState = enum { idle, authenticating, negotiating, awaiting_frame, streaming, failed, closed };
pub const ManagementState = enum { idle, authenticating, available, unavailable, closed };
pub const Cleanup = enum { not_started, awaiting, unknown, released };
pub const FailureStage = enum { route, identity, trust, authentication, management, video, cleanup };
pub const ControlReply = enum { full_control, video_only, reject };
pub const ControlState = enum { read_only, major, awaiting_authorization, rejected };
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    operation: operations.OperationKey,
    name: []const u8 = "",
    target: []const u8 = "",
    route_summary: []const u8 = "",
    route: RouteState = .frozen,
    video: VideoState = .idle,
    management: ManagementState = .idle,
    cleanup: Cleanup = .not_started,
    input: remote_input.Snapshot,
    control: ControlState = .read_only,
    control_request: ?[4]u8 = null,
    failure_stage: ?FailureStage = null,
    failure_code: ?[]const u8 = null,
    progress: progress.Snapshot = .{},
    width: u32 = 0,
    height: u32 = 0,
    stride: usize = 0,
    format: framebuffer.Format = .rgba8,
    frame_sequence: u64 = 0,
    frame_generation: u64 = 0,
    rfb_ready: bool = false,
    read_only_requested: bool = false,
    /// These remote logout receipts describe only our own remote sessions.
    /// They never substitute for the local cleanup/FrameLease barrier.
    remote_web_logout: enum { not_created, awaiting, confirmed, unknown } = .not_created,
    remote_kvm_logout: enum { not_created, awaiting, confirmed, unknown } = .not_created,
};
pub const OwnedSnapshot = services.Owned(Snapshot);
pub const Interface = struct {
    snapshot: *const fn (*anyopaque, typed.Binding, std.mem.Allocator) anyerror!OwnedSnapshot,
    request_control: *const fn (*anyopaque, typed.Binding) anyerror!void,
    reply_control: *const fn (*anyopaque, typed.Binding, [4]u8, ControlReply) anyerror!void,
    refresh: *const fn (*anyopaque, typed.Binding) anyerror!void,
    set_focus: *const fn (*anyopaque, typed.Binding, bool) anyerror!void,
    /// Queue a main-thread SessionHost close/retry. No connection or IO runs
    /// inside this call. The old instance must report released before retry.
    retry: *const fn (*anyopaque, typed.Binding) anyerror!void,
    /// Queue cancellation on the owner thread; keep the tab's diagnostics.
    cancel: ?*const fn (*anyopaque, typed.Binding) anyerror!void = null,
};
pub const definition = typed.Definition.of(Interface, key);
