//! Restricted UI slots supplied by the host. Plugins receive neither the
//! application root nor the workspace or native protocol implementation.
const std = @import("std");
const ui = @import("ui");
const identity = @import("identity.zig");
const envelope = @import("../config/connection_envelope.zig");

pub const SubmitIntent = enum { save, save_and_open, temporary, probe };
pub const EditorEvents = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque) void,
    submit: *const fn (*anyopaque, envelope.Envelope, SubmitIntent) anyerror!void,
    dismiss: ?*const fn (*anyopaque) void = null,
    cancelled: ?*const fn (*anyopaque) void = null,
};
pub const EditorMount = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    slot: *ui.Node,
    protocol_id: []const u8,
    initial: ?envelope.Envelope = null,
    draft_revision: u64,
    events: EditorEvents,
    editor_host: ?*@import("content_context.zig").EditorHost = null,
    editor_id: u64 = 0,
    connection_configs: ?@import("connection_config_resolver.zig").Resolver = null,
};
pub const EditorInstance = struct {
    context: *anyopaque,
    vtable: *const VTable,
    handles_actions: bool = false,
    pub const VTable = struct {
        snapshot: *const fn (*anyopaque, std.mem.Allocator) anyerror!envelope.Envelope,
        clear_secrets: *const fn (*anyopaque) void,
        unmount: *const fn (*anyopaque) void,
        cancel: ?*const fn (*anyopaque) void = null,
        visibility_changed: ?*const fn (*anyopaque, bool) void = null,
        child_completed: ?*const fn (*anyopaque, @import("content_context.zig").ChildCompletion) void = null,
    };
};
pub const EditorFactory = struct {
    context: ?*anyopaque = null,
    /// Existing SSH/SFTP share the fully featured editor supplied by the host.
    /// The contribution chooses that shared editor; protocol IDs do not.
    mount: ?*const fn (?*anyopaque, EditorMount) anyerror!EditorInstance = null,
    shared_editor: ?[]const u8 = null,
};
pub const ContentMount = struct {
    cx: *ui.Cx,
    scope: *ui.Scope,
    slot: *ui.Node,
    owner: identity.SessionHandle,
    connection: envelope.Envelope,
    content_context: ?*@import("content_context.zig").Context = null,
    frame_sink: ?*@import("frame_texture_sink.zig").Sink = null,
};
pub const ContentUpdate = struct {
    owner: identity.SessionHandle,
    revision: u64,
    title: []const u8,
    status: []const u8,
};
pub const RendererInstance = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        update: *const fn (*anyopaque, ContentUpdate) anyerror!void,
        focus_changed: *const fn (*anyopaque, bool) void,
        unmount: *const fn (*anyopaque) void,
    };
};
pub const RendererDefinition = struct {
    kind: []const u8,
    context: ?*anyopaque = null,
    /// Shared terminal/file renderers stay bound by the existing engine bridge.
    mount: ?*const fn (?*anyopaque, ContentMount) anyerror!RendererInstance = null,
    shared_renderer: bool = false,
    supports_window_transfer: bool = false,
};

pub const ContentServices = struct {
    content_context: ?*@import("content_context.zig").Context = null,
    frame_sink: ?*@import("frame_texture_sink.zig").Sink = null,
};
pub const ContentServicesFactory = struct {
    context: *anyopaque,
    create: *const fn (*anyopaque, identity.SessionHandle) anyerror!ContentServices,
};
