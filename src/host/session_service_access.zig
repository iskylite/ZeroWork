//! A renderer's main-thread lookup capability is frozen to its complete owner.
//! Returned bindings are borrowed capabilities; providers must revalidate them
//! on each operation, including after authorization or generation changes.
const identity = @import("identity.zig");
const typed = @import("plugin_services.zig");

pub const api_id = "host.session_service_access";
pub const api_major: u32 = 1;

pub const SessionServiceAccess = struct {
    context: *anyopaque,
    owner: identity.SessionHandle,
    lookup_fn: *const fn (*anyopaque, identity.SessionHandle, typed.Definition) anyerror!?typed.Binding,

    /// null means unsupported. StaleSession, ServiceNotReady, ServiceDenied,
    /// ServiceTypeMismatch and ServiceLookupOffMainThread remain distinct.
    pub fn lookup(self: SessionServiceAccess, owner: identity.SessionHandle, definition: typed.Definition) !?typed.Binding {
        if (!self.owner.eql(owner)) return error.OwnerMismatch;
        return self.lookup_fn(self.context, owner, definition);
    }

    pub fn lookupCurrent(self: SessionServiceAccess, definition: typed.Definition) !?typed.Binding {
        return self.lookup(self.owner, definition);
    }
};
