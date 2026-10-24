//! Yix var x: []u8 = signal(...): mutable slice as signal value unclear if borrow or copy, compile
//! error requires []const E.
const ui = @import("ui");
test {
    var buf = [_]u8{ 1, 2 };
    const scope: *ui.Scope = undefined;
    _ = try scope.createSignalFor([]u8, &buf);
}
