const std = @import("std");
pub const Mode = enum { confirm, auto };
pub const Verdict = enum { allow_auto, need_confirm, deny_exec_copy_only };
pub const Engine = struct { mode: Mode = .confirm };
/// Only the mode changes while a worker runs; command templates stay owned by
/// the request. The UI and worker never mutate/read the same plain enum.
pub const LiveMode = struct {
    const Value = enum(u8) { inherit, confirm, auto };
    value: std.atomic.Value(Value) = .init(.inherit),
    pub fn set(self: *LiveMode, mode: Mode) void {
        self.value.store(if (mode == .auto) .auto else .confirm, .release);
    }
    pub fn reset(self: *LiveMode) void {
        self.value.store(.inherit, .release);
    }
    pub fn apply(self: *const LiveMode, engine: Engine) Engine {
        var result = engine;
        result.mode = switch (self.value.load(.acquire)) {
            .inherit => engine.mode,
            .confirm => .confirm,
            .auto => .auto,
        };
        return result;
    }
};
pub fn commandVerdict(engine: Engine) Verdict {
    return if (engine.mode == .auto) .allow_auto else .need_confirm;
}

test "command approval depends only on the permission mode" {
    try std.testing.expectEqual(Verdict.need_confirm, commandVerdict(.{}));
    try std.testing.expectEqual(Verdict.allow_auto, commandVerdict(.{ .mode = .auto }));
}
