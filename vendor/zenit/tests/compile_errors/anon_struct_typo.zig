// expect: P.offset: anon_struct_typo.Pt has no field 'z'
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
pub const Pt = struct { x: f32 = 0, y: f32 = 0 };
const P = struct { offset: r.Source(Pt) = .{ .value = .{} } };
test {
    _ = r.props.coerce(P, .{ .offset = .{ .z = 1 } });
}
