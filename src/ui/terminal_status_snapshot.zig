//! Scalar facts from a consumed terminal publication, never a PTY request or
//! a configured encoding default. Safe to retain after the source frame moves.
const identity = @import("../host/identity.zig");
const operation = @import("../host/operation.zig");
const frame = @import("../vt/text_frame.zig");
pub const Encoding = enum { unknown, utf8 };
pub const Snapshot = struct {
    owner: identity.SessionHandle,
    operation_key: ?operation.OperationKey = null,
    /// Real service geometry revision or consumed SSH frame publication.
    revision: u64,
    cols: u16,
    rows: u16,
    encoding: Encoding = .unknown,
    /// SSH text publications must have passed the production wire decoder.
    frame_version: ?u8 = null,

    pub fn accepts(self: Snapshot, key: operation.OperationKey) bool {
        if (key.owner != .session or !self.owner.eql(key.owner.session) or self.revision == 0 or self.cols == 0 or self.rows == 0) return false;
        if (self.operation_key) |source| {
            if (!source.eql(key) or self.frame_version != frame.frame_version) return false;
        } else if (self.frame_version != null) return false;
        return true;
    }
};
