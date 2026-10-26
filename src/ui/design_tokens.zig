//! Shared SPEC design colors used by native views and design previews.
const ui = @import("ui");

pub const tok = struct {
    pub const bg = ui.Color.rgb(0xEC, 0xFF, 0xF4); // --bg
    pub const chrome = ui.Color.rgb(0xE2, 0xF5, 0xEB); // --chrome
    pub const sidebar = ui.Color.rgb(0xE5, 0xF7, 0xED); // --sidebar
    pub const tabin = ui.Color.rgb(0xD5, 0xEC, 0xE0); // --tabin
    pub const fg = ui.Color.rgb(0x0F, 0x17, 0x2A); // --fg
    pub const fg2 = ui.Color.rgb(0x47, 0x55, 0x69); // --fg2
    pub const fg3 = ui.Color.rgb(0x94, 0xA3, 0xB8); // --fg3
    pub const acc = ui.Color.rgb(0x13, 0x45, 0xF6); // --acc
    pub const acc2 = ui.Color.rgb(0x3B, 0x82, 0xF6); // --acc2
    pub const bd = ui.Color.rgb(0xCF, 0xE5, 0xD8); // --bd
    pub const grn = ui.Color.rgb(0x10, 0xB9, 0x81); // --grn
    pub const red = ui.Color.rgb(0xDC, 0x4C, 0x3F); // --red
    pub const yel = ui.Color.rgb(0xD4, 0x9A, 0x0C); // --yel
    pub const cyn = ui.Color.rgb(0x06, 0xB6, 0xD4); // --cyn
    pub const mag = ui.Color.rgb(0xC2, 0x41, 0xE0); // --mag
    pub const pur = ui.Color.rgb(0x8B, 0x5C, 0xF6); // --pur
    pub const stbg = ui.Color.rgb(0xD8, 0xEF, 0xE1); // --stbg
    /// 设置模态系（浅灰而非薄荷绿）
    pub const setbd = ui.Color.rgb(0xE2, 0xE8, 0xF0); // settings --bd
    pub const setnav = ui.Color.rgb(0xEF, 0xF9, 0xF2); // settings Nav 底
    pub const card = ui.Color.rgb(0xF8, 0xFA, 0xFC); // 卡片底
    pub const btn_sec_bg = ui.Color.rgb(0xF1, 0xF5, 0xF9); // 次按钮底
    pub const row_sep = ui.Color.rgb(0xF2, 0xF9, 0xF4); // 设置行分隔
    pub const off_dot = ui.Color.rgb(0xCB, 0xD5, 0xE1); // 离线状态点
    pub const white = ui.Color.rgb(0xFF, 0xFF, 0xFF);

    /// token 的 alpha 变体（等效 CSS rgba(token, a/255)）。
    pub fn alpha(color: ui.Color, a: u8) ui.Color {
        return ui.Color.rgba(color.r, color.g, color.b, a);
    }
};
