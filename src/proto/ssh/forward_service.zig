//! SOCKS commands/snapshots over the existing SSH native IO owner. Listener has
//! no thread in this mode: Worker.step or the selected hop Relay drives it.
//! The controller never receives a Session, channel, fd, or Listener pointer.
const std = @import("std");
const ssh = @import("session.zig");
const socks = @import("socks5_listener.zig");
const sessions = @import("../../host/session_host.zig");
const operations = @import("../../host/operation.zig");

pub const Phase = enum { off, starting, running, paused, stopping, failed, cleanup_unknown };
pub const Snapshot = struct {
    origin: ?operations.OperationKey = null,
    binding: ?sessions.ServiceHandle = null,
    key: ?operations.OperationKey = null,
    phase: Phase = .off,
    port: u16 = 0,
    options: socks.Options = .{},
    stats: socks.Stats = .{},
    cleanup: ssh.ReleaseReceipt = .released,
    failure: ?anyerror = null,
};
const Start = struct { origin: operations.OperationKey, binding: sessions.ServiceHandle, key: operations.OperationKey, options: socks.Options };

pub const Service = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Value(bool) = .init(false),
    published: Snapshot,
    pending: ?Start = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    parent_close_requested: std.atomic.Value(bool) = .init(false),
    // These fields belong exclusively to the current native IO owner.
    listener: ?*socks.Socks5Listener = null,
    transport_paused: bool = false,

    pub fn init(allocator: std.mem.Allocator, original: ?operations.OperationKey) !*Service {
        const self = try allocator.create(Service);
        self.* = .{ .allocator = allocator, .published = .{ .origin = original } };
        return self;
    }
    fn lock(self: *Service) void {
        while (self.mutex.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Service) void {
        self.mutex.store(false, .release);
    }
    pub fn snapshot(self: *Service) Snapshot {
        self.lock();
        defer self.unlock();
        return self.published;
    }
    /// Memory-only acceptance against the actual original forward binding.
    pub fn start(self: *Service, origin: operations.OperationKey, binding: sessions.ServiceHandle, key: operations.OperationKey, options: socks.Options) !void {
        self.lock();
        defer self.unlock();
        if (origin.owner != .session or key.owner != .session or !origin.owner.session.eql(key.owner.session) or key.operation_id == 0 or origin.attempt_id != key.attempt_id or binding.kind != .forward or binding.resource_owner != .session or !binding.resource_owner.session.eql(key.owner.session) or binding.origin_session == null or !binding.origin_session.?.eql(key.owner.session) or binding.binding_generation != key.owner.session.generation or binding.binding_id == 0) return error.InvalidForwardAuthority;
        if (self.published.origin == null or !self.published.origin.?.eql(origin)) return error.StaleForwardOrigin;
        if (self.pending != null or (self.published.phase != .off and self.published.phase != .paused and self.published.phase != .failed)) return error.ForwardServiceBusy;
        if (!options.bind127 and !options.exposure_confirmed) return error.ExposureConfirmationRequired;
        if (options.max_connections == 0) return error.InvalidForwardLimit;
        if (self.published.phase == .paused and !std.meta.eql(self.published.options, options)) return error.ForwardOptionsRequireStop;
        self.pending = .{ .origin = origin, .binding = binding, .key = key, .options = options };
        self.published.binding = binding;
        self.published.key = key;
        self.published.options = options;
        self.published.phase = .starting;
        self.published.cleanup = .awaiting;
        self.published.failure = null;
        self.stop_requested.store(false, .release);
        self.parent_close_requested.store(false, .release);
    }
    pub fn requestStop(self: *Service, binding: sessions.ServiceHandle) ssh.ReleaseReceipt {
        self.lock();
        defer self.unlock();
        if (self.published.binding == null or !self.published.binding.?.eql(binding)) return .released;
        if (self.published.cleanup == .released) return .released;
        self.stop_requested.store(true, .release);
        self.published.phase = .stopping;
        return self.published.cleanup;
    }
    /// The original runtime's final close also covers a start still queued by
    /// its controller. This only submits a flag; it performs no native IO.
    pub fn requestClose(self: *Service) void {
        self.stop_requested.store(true, .release);
    }
    /// Only the original SessionHost close hook submits this stronger intent.
    /// A stalled OPEN belongs to the parent native graph until it is actually
    /// released. Ordinary proxy stop never requests a PTY/transport close.
    pub fn requestParentClose(self: *Service, origin: operations.OperationKey, binding: sessions.ServiceHandle) ssh.ReleaseReceipt {
        self.lock();
        defer self.unlock();
        if (self.published.origin == null or !self.published.origin.?.eql(origin) or self.published.binding == null or !self.published.binding.?.eql(binding)) return .released;
        if (self.published.cleanup == .released) return .released;
        self.stop_requested.store(true, .release);
        self.parent_close_requested.store(true, .release);
        self.published.phase = .stopping;
        return self.published.cleanup;
    }
    pub fn parentCloseRequested(self: *Service) bool {
        return self.parent_close_requested.load(.acquire);
    }
    /// Only after the previous Worker/Relay stopped and joined. This transfers
    /// its stable retry buffers with the Session to the cleanup owner.
    pub fn adoptIoAfterOwnerStopped(self: *Service) void {
        if (self.listener) |listener| listener.owner_thread = null;
    }
    fn publish(self: *Service, phase: Phase, receipt: ssh.ReleaseReceipt, reason: ?anyerror) void {
        self.lock();
        defer self.unlock();
        self.published.phase = phase;
        self.published.cleanup = receipt;
        self.published.failure = reason;
        if (self.listener) |listener| {
            self.published.port = listener.port();
            self.published.stats = listener.stats();
        } else self.published.port = 0;
    }
    /// Native-owner only. No mutex encloses libssh2 or native retries.
    pub fn step(self: *Service, session: *ssh.Session) !void {
        self.lock();
        const previous = self.published.origin;
        self.published.origin = session.resource_key;
        const pending = self.pending;
        self.pending = null;
        self.unlock();
        if (self.stop_requested.load(.acquire)) {
            self.stopNative();
            return;
        }
        if (pending) |request| {
            if (session.resource_key == null or !session.resource_key.?.eql(request.origin)) {
                self.publish(if (self.listener != null) .paused else .failed, if (self.listener != null) .awaiting else .released, error.StaleForwardOrigin);
                return;
            }
            if (self.listener) |listener| {
                listener.ownerResume(session) catch |err| {
                    self.publish(.cleanup_unknown, .unknown, err);
                    return;
                };
            } else {
                self.listener = socks.Socks5Listener.initOwnerDriven(self.allocator, session) catch |err| {
                    self.publish(.failed, .released, err);
                    return;
                };
                self.listener.?.startWithOptions(request.options) catch |err| {
                    self.listener.?.deinit();
                    self.listener = null;
                    self.publish(.failed, .released, err);
                    return;
                };
            }
            self.transport_paused = false;
        } else if (previous != null and session.resource_key != null and !previous.?.eql(session.resource_key.?)) {
            // A replacement transport is authenticated; only the controller's
            // new live binding/key may resume the retained listening port.
            self.transport_paused = true;
        }
        if (self.listener) |listener| {
            try listener.ownerStep();
            if (listener.state() == .error_state and !self.transport_paused) {
                const reason = listener.last_failure orelse error.ForwardListenFailed;
                const receipt = listener.ownerStop();
                if (receipt == .released) {
                    listener.deinit();
                    self.listener = null;
                }
                self.publish(.failed, receipt, reason);
                return;
            }
            self.publish(if (self.transport_paused) .paused else if (listener.state() == .starting) .starting else .running, .awaiting, listener.last_failure);
        }
    }
    fn stopNative(self: *Service) void {
        self.lock();
        self.pending = null;
        self.unlock();
        const listener = self.listener orelse {
            self.publish(.off, .released, null);
            return;
        };
        const receipt = listener.ownerStop();
        if (receipt == .released) {
            self.publish(.off, .released, null);
            listener.deinit();
            self.listener = null;
        } else self.publish(if (receipt == .unknown) .cleanup_unknown else .stopping, receipt, null);
    }
    /// Called by the actual Session owner before its existing teardown path.
    pub fn transportLost(self: *Service) !void {
        self.transport_paused = true;
        if (self.listener) |listener| try listener.ownerPause();
        if (self.listener != null) self.publish(.paused, .awaiting, null);
    }
    /// The parent owner supplies this only after Session.closeReceipt released.
    pub fn sessionReleased(self: *Service) !void {
        self.transport_paused = true;
        if (self.listener) |listener| try listener.ownerSessionReleased();
        if (self.stop_requested.load(.acquire)) self.stopNative() else if (self.listener != null) self.publish(.paused, .awaiting, null);
    }
    /// After parent release, the stopped owner's local driver keeps the port
    /// responsive: paused CONNECT receives network_unreachable, with no SSH IO.
    pub fn stepPaused(self: *Service) !void {
        if (self.stop_requested.load(.acquire)) {
            self.stopNative();
            return;
        }
        if (self.listener) |listener| {
            if (listener.session != null) return error.ParentTransportNotReleased;
            try listener.ownerStep();
            self.publish(.paused, .awaiting, null);
        }
    }
    pub fn prepareReplacement(self: *Service) !void {
        if (self.listener) |listener| {
            if (listener.session != null or listener.pending_open != null or listener.pending_close != null) return error.PreviousTransportNotReleased;
            // Native ownership ended with the real parent receipt. The old
            // Worker/Relay has stopped local ticks before this explicit move.
            listener.owner_thread = null;
        }
    }
    pub fn hasListener(self: *Service) bool {
        const value = self.snapshot();
        return value.cleanup != .released;
    }
    /// Never destroys a retained port or an EAGAIN child owner.
    pub fn deinitLocal(self: *Service) error{Busy}!void {
        if (self.listener != null or self.pending != null or self.snapshot().cleanup != .released) return error.Busy;
        self.allocator.destroy(self);
    }
};
