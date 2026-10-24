// expect: ui.split is only for controlled-value props (Model)
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
const P = struct { disabled: r.Source(bool) = .{ .value = false } };
const S = struct {
    fn w(_: *@This(), _: bool) void {}
};
test {
    const f = try fixture();
    const s = try f.scope.createSignal(bool, true);
    var st = S{};
    _ = r.props.coerce(P, .{ .disabled = r.split(s, r.Callback(bool).from(S, &st, S.w)) });
}
