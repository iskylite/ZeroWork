// expect: the prop is optional, use a Signal(?u32) or ui.map to wrap it
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
const P = struct { sel: r.Source(?u32) = .{ .value = null } };
test {
    const f = try fixture();
    const s = try f.scope.createSignal(u32, 1);
    _ = r.props.coerce(P, .{ .sel = s });
}
