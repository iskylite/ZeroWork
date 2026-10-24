// expect: a static value would never change
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
const S = struct {
    fn w(_: *@This(), _: bool) void {}
};
test {
    var st = S{};
    _ = r.split(true, r.Callback(bool).from(S, &st, S.w));
}
