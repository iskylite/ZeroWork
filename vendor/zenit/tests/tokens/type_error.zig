const theme = @import("example");
comptime {
    // A color reference must not be accepted where a space reference is expected.
    _ = theme.resolve(.space, theme.refs.color.surface, &theme.modes.dark);
}
