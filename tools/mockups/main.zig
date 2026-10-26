//! mockup-main — 主窗口设计稿复刻（docs/SPEC/html/mockup-main.html）。
//!
//! 参考实现（其他 mockup 文件遵循同样的模式）：
//!  - pub const window_size / title 供预览入口使用；
//!  - mount() 返回铺满窗口的节点树，静态数据与 HTML 一致；
//!  - 颜色一律走 common.tok，布局尺寸逐条对照 HTML CSS。
//!
//! 结构：tbar(40) + main(592: sb 224 + ta) + sbar(28)。窗口 1280×660。

const std = @import("std");
const ui = @import("ui");
const mock = @import("common.zig");

pub const window_size = .{ .width = 1280, .height = 660 };
pub const title = "mockup-main";

const tok = mock.tok;

pub fn mount(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    _ = scope;
    const root = try mock.windowRoot(cx, .{
        try mountTitleBar(cx),
        try mountMain(cx),
        try mountStatusBar(cx),
        try mountHoverTooltip(cx),
    });
    return root;
}

// ── 标题栏 + 页签（tbar 40px） ─────────────────────────────────────

fn mountTitleBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 40 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.chrome,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, -1, 1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // 红绿灯组：12px 圆，gap 8，右缘 10（预览程序的原生红绿灯与此位置重叠）。
    const tls = try ui.box(cx, .{
        .direction = .row,
        .gap = 8,
        .margin = .{ .top = 0, .right = 10, .bottom = 0, .left = 0 },
        .flex_shrink = 0,
    }, .{});
    for ([_]ui.Color{ ui.Color.rgb(0xFF, 0x5F, 0x57), ui.Color.rgb(0xFF, 0xBD, 0x2E), ui.Color.rgb(0x28, 0xC8, 0x40) }) |c| {
        try tls.appendChild(cx.allocator, try mock.dot(cx, 12, c));
    }
    try bar.appendChild(cx.allocator, tls);

    // 页签 ×3：生产网关(off) / K8s-Node01(on) / RDS-PGD(off)
    try bar.appendChild(cx.allocator, try tab(cx, "生产网关", false));
    try bar.appendChild(cx.allocator, try tab(cx, "K8s-Node01", true));
    try bar.appendChild(cx.allocator, try tab(cx, "RDS-PG", false));

    // ＋ 新页签
    const add = try ui.box(cx, .{
        .width = .{ .px = 24 },
        .height = .{ .px = 24 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 6 },
        .flex_shrink = 0,
    }, .{});
    try add.appendChild(cx.allocator, try ui.text(cx, "+", .{ .font_size = 14, .color = tok.fg3 }));
    try bar.appendChild(cx.allocator, add);

    try bar.appendChild(cx.allocator, try ui.spacer(cx));

    // 右侧全局图标：⚡ ⇅(badge 1) ✨(acc) ⚙️
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚡", null));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⇅", "1"));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "✨", null));
    try bar.appendChild(cx.allocator, try globalIcon(cx, "⚙️", null));
    return bar;
}

fn tab(cx: *ui.Cx, name: []const u8, on: bool) !*ui.Node {
    const node = try ui.box(cx, .{
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 12, .right = 12, .top = 0, .bottom = 0 },
        .background = if (on) tok.bg else ui.Color.TRANSPARENT,
        .border = .{ .width = 1, .color = tok.bd, .radius = 7 },
        .shadow = if (on) .{ .blur = 3, .offset_y = 1, .color = ui.Color.rgba(0, 0, 0, 20) } else null,
        .flex_shrink = 0,
    }, .{});
    try node.appendChild(cx.allocator, try mock.dot(cx, 6, if (on) tok.grn else tok.off_dot));
    try node.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.fg else tok.fg2,
    }));
    try node.appendChild(cx.allocator, try ui.text(cx, "✕", .{ .font_size = 9, .color = tok.fg3 }));
    return node;
}

fn globalIcon(cx: *ui.Cx, icon: []const u8, badge_text: ?[]const u8) !*ui.Node {
    const icn = try ui.box(cx, .{
        .width = .{ .px = 30 },
        .height = .{ .px = 28 },
        .align_items = .center,
        .justify = .center,
        .border = .{ .width = 0, .color = tok.bd, .radius = 7 },
        .flex_shrink = 0,
    }, .{});
    try icn.appendChild(cx.allocator, try ui.text(cx, icon, .{
        .font_size = 14,
        .color = if (std.mem.eql(u8, icon, "✨")) tok.acc else tok.fg2,
    }));
    if (badge_text) |bt| {
        const bdg = try ui.box(cx, .{
            .position = .absolute,
            .inset = .{ .top = .{ .px = 1 }, .right = .{ .px = 0 } },
            .height = .{ .px = 13 },
            .min_width = 13,
            .direction = .row,
            .align_items = .center,
            .justify = .center,
            .padding = .{ .left = 3, .right = 3, .top = 0, .bottom = 0 },
            .background = tok.grn,
            .border = .{ .width = 0, .color = tok.grn, .radius = 7 },
        }, .{});
        try bdg.appendChild(cx.allocator, try ui.text(cx, bt, .{
            .font_size = 8.5,
            .font_weight = 600,
            .color = tok.white,
        }));
        try icn.appendChild(cx.allocator, bdg);
    }
    return icn;
}

// ── 主体（main：侧栏 224 + 终端区） ───────────────────────────────

fn mountMain(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .row,
        .flex_shrink = 0,
    }, .{
        try mountSidebar(cx),
        try mountTerminalArea(cx),
    });
}

fn mountSidebar(cx: *ui.Cx) !*ui.Node {
    const sb = try ui.box(cx, .{
        .width = .{ .px = 224 },
        .height = .fill(),
        .direction = .column,
        .background = tok.sidebar,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, 1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    // 分组标题
    const sb_h = try ui.box(cx, .{
        .width = .fill(),
        .padding = .{ .left = 14, .right = 14, .top = 11, .bottom = 7 },
        .flex_shrink = 0,
    }, .{});
    try sb_h.appendChild(cx.allocator, try ui.text(cx, "主机与连接", .{
        .font_size = 10,
        .font_weight = 600,
        .color = tok.fg2,
    }));
    try sb.appendChild(cx.allocator, sb_h);

    // 搜索框（静态外观）
    const sb_s = try ui.box(cx, .{
        .height = .{ .px = 30 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .margin = .{ .top = 0, .right = 10, .bottom = 8, .left = 10 },
        .padding = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 },
        .background = tok.alpha(tok.white, 153), // rgba(255,255,255,.6)
        .border = .{ .width = 1, .color = tok.bd, .radius = 6 },
        .flex_shrink = 0,
    }, .{});
    try sb_s.appendChild(cx.allocator, try ui.text(cx, "🔍", .{ .font_size = 11, .color = tok.fg2 }));
    try sb_s.appendChild(cx.allocator, try ui.text(cx, "搜索主机或标签…", .{ .font_size = 11.5, .color = tok.fg2 }));
    try sb.appendChild(cx.allocator, sb_s);

    // 分组：Production
    try sb.appendChild(cx.allocator, try groupHeader(cx, "▼ Production"));
    try sb.appendChild(cx.allocator, try hostRow(cx, "Bastion-01", "118.31.22.10 · Direct", true, false));
    try sb.appendChild(cx.allocator, try hostRow(cx, "K8s-Node01", "10.200.1.18 · via Bastion", true, true));
    try sb.appendChild(cx.allocator, try hostRow(cx, "K8s-Node02", "10.200.1.19 · via Bastion", true, false));
    try sb.appendChild(cx.allocator, try hostRow(cx, "DB-Master", "10.200.4.18 · 2级跳板", false, false));

    // 分组：Staging
    try sb.appendChild(cx.allocator, try groupHeader(cx, "▼ Staging"));
    try sb.appendChild(cx.allocator, try hostRow(cx, "Staging-API", "172.16.0.5 · Direct", false, false));
    try sb.appendChild(cx.allocator, try hostRow(cx, "Staging-Redis", "172.16.0.12 · Direct", false, false));

    try sb.appendChild(cx.allocator, try ui.spacer(cx));

    // 底部新建
    const footer = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 37 },
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .background = tok.sidebar,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try footer.appendChild(cx.allocator, try ui.text(cx, "＋ 新建连接配置", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    try sb.appendChild(cx.allocator, footer);
    return sb;
}

fn groupHeader(cx: *ui.Cx, name: []const u8) !*ui.Node {
    const gh = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 21 },
        .direction = .row,
        .align_items = .center,
        .gap = 5,
        .padding = .{ .left = 14, .right = 14, .top = 5, .bottom = 5 },
        .flex_shrink = 0,
    }, .{});
    try gh.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 11,
        .font_weight = 600,
        .color = tok.fg2,
    }));
    return gh;
}

fn hostRow(cx: *ui.Cx, name: []const u8, meta: []const u8, online: bool, on: bool) !*ui.Node {
    const hi = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 44 },
        .direction = .row,
        .align_items = .center,
        .gap = 8,
        .padding = .{ .left = 26, .right = 14, .top = 6, .bottom = 6 },
        .background = if (on) tok.alpha(tok.acc, 20) else ui.Color.TRANSPARENT,
        .flex_shrink = 0,
    }, .{});
    try hi.appendChild(cx.allocator, try mock.dot(cx, 7, if (online) tok.grn else tok.off_dot));
    const labels = try ui.box(cx, .{
        .direction = .column,
        .gap = 1,
        .flex = 1,
        .min_width = 0,
    }, .{});
    try labels.appendChild(cx.allocator, try ui.text(cx, name, .{
        .font_size = 12.5,
        .font_weight = if (on) 500 else 400,
        .color = if (on) tok.acc else tok.fg,
    }));
    try labels.appendChild(cx.allocator, try ui.text(cx, meta, .{
        .font_size = 10,
        .color = tok.fg2,
    }));
    try hi.appendChild(cx.allocator, labels);
    return hi;
}

// ── 终端区（ta：双分栏） ───────────────────────────────────────────

fn mountTerminalArea(cx: *ui.Cx) !*ui.Node {
    return ui.box(cx, .{
        .width = .fill(),
        .height = .fill(),
        .direction = .row,
        .overflow = .hidden,
    }, .{
        try mountPane1(cx),
        try mountPane2(cx),
    });
}

fn paneLabel(cx: *ui.Cx, label: []const u8) !*ui.Node {
    const pl = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 6 }, .right = .{ .px = 10 } },
        .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 },
        .background = tok.chrome,
        .border = .{ .width = 0, .color = tok.bd, .radius = 4 },
        .opacity = 0.75,
    }, .{});
    try pl.appendChild(cx.allocator, try ui.text(cx, label, .{
        .font_size = 10,
        .color = tok.fg2,
    }));
    return pl;
}

fn mountPane1(cx: *ui.Cx) !*ui.Node {
    const tp = try ui.box(cx, .{
        .flex = 1,
        .height = .fill(),
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .overflow = .hidden,
    }, .{});
    try tp.appendChild(cx.allocator, try paneLabel(cx, "K8s-Node01 · Split 1"));

    // 颜色语义（html）：tu=cyn tb=acc2 td=.55(opacity) tg=grn ty=yel tr=red
    const td = tok.alpha(tok.fg, 140); // opacity .55 近似
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ uptime", .color = tok.fg },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = " 14:22:05 up 85 days, 2:14, 1 user, load average: 0.12, 0.08, 0.05", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ free -h", .color = tok.fg },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "               total        used        free      shared  buff/cache", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Mem:           ", .color = td },
        .{ .text = "31Gi", .color = tok.alpha(tok.grn, 140) },
        .{ .text = "       ", .color = td },
        .{ .text = "8.2Gi", .color = tok.alpha(tok.yel, 140) },
        .{ .text = "        ", .color = td },
        .{ .text = "20Gi", .color = tok.alpha(tok.grn, 140) },
        .{ .text = "       256Mi       3.1Gi", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Swap:         ", .color = td },
        .{ .text = "2.0Gi", .color = tok.alpha(tok.grn, 140) },
        .{ .text = "          0B       ", .color = td },
        .{ .text = "2.0Gi", .color = tok.alpha(tok.grn, 140) },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ tail -f /var/log/syslog", .color = tok.fg },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Oct  8 14:20:01 node01 CRON[8127]: (root) CMD (/usr/local/bin/health-check)", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Oct  8 14:20:05 node01 kubelet[1024]: I1008 Container synced successfully", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Oct  8 14:21:15 node01 sshd[9210]: Accepted publickey for ubuntu", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Oct  8 14:22:01 node01 kubelet[1024]: W1008 Pod eviction threshold", .color = tok.yel },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "Oct  8 14:22:05 node01 CRON[8135]: (root) CMD (metrics-push)", .color = td },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = " ", .color = tok.fg },
        .{ .text = "ubuntu", .color = tok.cyn },
        .{ .text = "@k8s-node01:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "$ ", .color = tok.fg },
    }, .{ .input = true, .cursor = true }));
    return tp;
}

fn mountPane2(cx: *ui.Cx) !*ui.Node {
    const tp = try ui.box(cx, .{
        .flex = 0.85,
        .height = .fill(),
        .direction = .column,
        .background = tok.bg,
        .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ -1, -1, -1, 1 } },
        .overflow = .hidden,
    }, .{});
    try tp.appendChild(cx.allocator, try paneLabel(cx, "K8s-Node02 · Split 2"));

    const td = tok.alpha(tok.fg, 140);
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "root", .color = tok.red },
        .{ .text = "@k8s-node02:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "# kubectl get pods -A", .color = tok.fg },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "NAMESPACE    NAME                    READY  STATUS", .color = td, .weight = 700 },
    }, .{}));
    try tp.appendChild(cx.allocator, try podsLine(cx, "kube-system  coredns-5dd5756b-v9hkm  ", "1/1", "Running"));
    try tp.appendChild(cx.allocator, try podsLine(cx, "kube-system  etcd-master-01          ", "1/1", "Running"));
    try tp.appendChild(cx.allocator, try podsLine(cx, "ingress      nginx-controller-7b89f  ", "1/1", "Running"));
    try tp.appendChild(cx.allocator, try podsLine(cx, "prod-app     backend-api-7b89f-k4m2q ", "2/2", "Running"));
    try tp.appendChild(cx.allocator, try podsLine(cx, "prod-app     backend-api-7b89f-x9p1r ", "2/2", "Running"));
    try tp.appendChild(cx.allocator, try podsLine(cx, "prod-app     worker-queue-91ca-hn7f2 ", "1/1", "Running"));
    // Pending 行：ty 色
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "prod-app     celery-beat-5f442-mv3kx ", .color = td },
        .{ .text = "0/1", .color = tok.alpha(tok.yel, 140) },
        .{ .text = "    ", .color = td },
        .{ .text = "Pending", .color = tok.alpha(tok.yel, 140) },
    }, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{.{ .text = "", .color = td }}, .{}));
    try tp.appendChild(cx.allocator, try mock.termLine(cx, &.{
        .{ .text = "root", .color = tok.red },
        .{ .text = "@k8s-node02:", .color = tok.fg },
        .{ .text = "~", .color = tok.acc2 },
        .{ .text = "# ", .color = tok.fg },
    }, .{ .input = true, .cursor = true }));
    return tp;
}

fn podsLine(cx: *ui.Cx, prefix: []const u8, ready: []const u8, status: []const u8) !*ui.Node {
    return mock.termLine(cx, &.{
        .{ .text = prefix, .color = tok.alpha(tok.fg, 140) },
        .{ .text = ready, .color = tok.alpha(tok.grn, 140) },
        .{ .text = "    ", .color = tok.alpha(tok.fg, 140) },
        .{ .text = status, .color = tok.alpha(tok.grn, 140) },
    }, .{});
}

// ── 状态栏（sbar 28px） ───────────────────────────────────────────

fn mountStatusBar(cx: *ui.Cx) !*ui.Node {
    const bar = try ui.box(cx, .{
        .width = .fill(),
        .height = .{ .px = 28 },
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .padding = .{ .left = 14, .right = 14, .top = 0, .bottom = 0 },
        .background = tok.stbg,
        .border = .{ .width = 1, .color = tok.bd, .radius = 0, .side_widths = .{ 1, -1, -1, -1 } },
        .flex_shrink = 0,
    }, .{});
    try bar.appendChild(cx.allocator, try mock.dot(cx, 6, tok.grn));
    try bar.appendChild(cx.allocator, try ui.text(cx, "Bastion-01 → k8s-node01", .{
        .font_size = 11,
        .color = tok.fg2,
    }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "RTT 24ms", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "UTF-8", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "120×36", .{ .font_size = 11, .color = tok.fg2 }));
    try bar.appendChild(cx.allocator, try mock.vsep(cx));
    try bar.appendChild(cx.allocator, try ui.text(cx, "⬡ ProxyJump", .{ .font_size = 11, .color = tok.acc }));

    try bar.appendChild(cx.allocator, try ui.spacer(cx));

    // 右侧传输进度
    const right = try ui.box(cx, .{
        .direction = .row,
        .align_items = .center,
        .gap = 6,
        .flex_shrink = 0,
    }, .{});
    try right.appendChild(cx.allocator, try ui.text(cx, "🚀", .{ .font_size = 11, .color = tok.fg2 }));
    try right.appendChild(cx.allocator, try ui.text(cx, "app.tar.gz", .{ .font_size = 11, .color = tok.fg2 }));
    const pbar = try ui.box(cx, .{
        .width = .{ .px = 110 },
        .height = .{ .px = 4 },
        .background = ui.Color.rgba(0, 0, 0, 20),
        .border = .{ .width = 0, .color = tok.bd, .radius = 2 },
        .overflow = .hidden,
        .flex_shrink = 0,
    }, .{});
    const fill = try ui.box(cx, .{
        .width = .{ .px = 75 }, // 68%
        .height = .fill(),
        .gradient = .{ .from = tok.grn, .to = ui.Color.rgb(0x34, 0xD3, 0x99), .direction = .horizontal },
        .border = .{ .width = 0, .color = tok.grn, .radius = 2 },
    }, .{});
    try pbar.appendChild(cx.allocator, fill);
    try right.appendChild(cx.allocator, pbar);
    try right.appendChild(cx.allocator, try ui.text(cx, "68%", .{
        .font_size = 11,
        .font_weight = 500,
        .color = tok.grn,
    }));
    try right.appendChild(cx.allocator, try ui.text(cx, "12.4 MB/s", .{
        .font_size = 11,
        .color = tok.alpha(tok.fg2, 140),
    }));
    try bar.appendChild(cx.allocator, right);
    return bar;
}

// ── hover 注释浮层（png 中的说明框，一并复刻） ─────────────────────

fn mountHoverTooltip(cx: *ui.Cx) !*ui.Node {
    const tip = try ui.box(cx, .{
        .position = .absolute,
        .inset = .{ .top = .{ .px = 290 }, .left = .{ .px = 236 } },
        .z_index = 60,
        .background = ui.Color.rgba(15, 23, 42, 235),
        .padding = .{ .left = 11, .right = 11, .top = 6, .bottom = 6 },
        .border = .{ .width = 0, .color = tok.fg, .radius = 8 },
        .shadow = .{ .blur = 20, .offset_y = 8, .color = ui.Color.rgba(0, 0, 0, 64) },
    }, .{});
    try tip.appendChild(cx.allocator, try ui.text(cx, "主机行 hover 快捷操作：▶ 连接 · ⧉ 复制配置 · ✏️ 编辑 · 🗑 删除", .{
        .font_size = 10.5,
        .color = tok.white,
    }));
    return tip;
}
