// expect: P.disabled: pass a mutable pointer (*Signal / *Memo)
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
const P = struct { disabled: r.Source(bool) = .{ .value = false } };
test {
    const f = try fixture();
    const s: *const r.Signal(bool) = try f.scope.createSignal(bool, true);
    _ = r.props.coerce(P, .{ .disabled = s });
}
