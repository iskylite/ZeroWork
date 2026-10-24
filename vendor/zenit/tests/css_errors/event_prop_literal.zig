//! Yix <Button onClick={true} />: onClick is event param, literal value won't work
const ui = @import("ui");
test {
    _ = ui.view.valueProp(ui.widgets.Button, "on_click", true);
}
