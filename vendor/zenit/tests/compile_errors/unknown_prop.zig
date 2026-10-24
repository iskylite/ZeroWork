// expect: P: unknown prop 'lable'
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
const P = struct { label: r.Source([]const u8) = .{ .value = "" } };
test {
    _ = r.props.coerce(P, .{ .lable = "x" });
}
