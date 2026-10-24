// expect: P.disabled: expected a source of bool, got *reactive.signal.Signal(u32) (value type u32)
const std = @import("std");
const r = @import("reactive");
fn fixture() !struct { owner: *r.SignalOwner, scope: *r.Scope } {
    const owner = try r.SignalOwner.init(std.testing.allocator);
    return .{ .owner = owner, .scope = try r.Scope.init(std.testing.allocator, null, owner) };
}
const P = struct { disabled: r.Source(bool) = .{ .value = false } };
test {
    const f = try fixture();
    const s = try f.scope.createSignal(u32, 1);
    _ = r.props.coerce(P, .{ .disabled = s });
}
