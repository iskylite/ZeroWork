// expect: ui.derive takes 1..3 sources
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
test {
    const f = try fixture();
    const a = try f.scope.createSignal(u32, 1);
    _ = r.derive(u32, .{ a, a, a, a }, struct {
        fn c(_: anytype) u32 {
            return 0;
        }
    }.c);
}
