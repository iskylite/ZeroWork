//! Yix <Button block={n += 1} /> these event statements given to data param (block: bool)
const ui = @import("ui");
fn run(_: anytype) void {}
test {
    _ = ui.view.eventProp(ui.widgets.Button, "block", run);
}
