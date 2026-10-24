// expect: P.checked: controlled-value props (Model) need a mutable *Signal(bool), got *const reactive.memo.Memo(bool)
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
const P = struct { checked: r.Model(bool) = .{ .local = false } };
test {
    const f = try fixture();
    defer f.owner.deinit();
    defer f.scope.dispose();
    const m: *const r.Memo(bool) = try f.scope.createMemo(bool, .{}, struct {
        fn c(_: anytype) bool {
            return true;
        }
    }.c);
    _ = r.props.coerce(P, .{ .checked = m });
}
