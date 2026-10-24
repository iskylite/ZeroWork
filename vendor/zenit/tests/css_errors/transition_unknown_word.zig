//! Words in transition description besides duration/easing are typos (previously silently ignored,
//! reverted to defaults).
const ui = @import("ui");
test {
    _ = ui.transition("background quik ease-out");
}
