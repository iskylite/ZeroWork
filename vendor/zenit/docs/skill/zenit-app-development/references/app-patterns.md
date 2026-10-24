# 应用入口与状态

先读实际依赖的 `templates/minimal-app/build.zig` 和 `src/main.zig`。下面对应当前 Zig 0.17 API；依赖版本不同必须核实声明。

```zig
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const v = ui.view;

fn inc(n: u32) u32 { return n + 1; }

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    const count = try scope.createSignal(u32, 0);
    return v.render(scope, cx, v.col(.{}, .{
        v.attrs(.{ .test_id = "counter.increment" }, ui.widgets.Button(.{
            .label = "Click me",
            .on_click = ui.on.update(count, inc),
        })),
        v.text(.{}, v.fmt("Clicked {d} times", .{count})),
    }));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 640, .height = 480, .title = "Counter" },
    });
    defer app.deinit();
    try app.runWith(mountUI);
}
```

这段只展示入口与交互；视觉布局在独立样式中定义。`runWith` 管理根 Scope 和事件循环，不要额外自己销毁传入 Scope。

| 需求 | 首选模式 | 核对位置 |
| --- | --- | --- |
| 点击写状态 | `ui.on.set/update/toggle` | `docs/GETTING_STARTED.md`，`src/ui/on.zig`（如路径变更用 rg 找声明） |
| 值事件写入 | `ui.on.assign`，受控 `Model(T)` | 组件 Props 与 `docs/SIGNAL_API_DESIGN.md` |
| 多 handler 共享业务状态 | `scope.createState` + `ui.on.call` | `src/ui/reactive/scope.zig` |
| 动态捕获 row id | `ui.on.bind(scope, ctx, f)` | 当前 handler 实现及 row scope |
| 文本输入 | `scope.createText` + Input 的 value | owning signal 的 set/get 契约 |
| 列表 | `scope.createList` + `v.each(items, .id, row)` | `docs/VIEW_DSL.md` 和对应 list 示例 |
| 业务资源清理 | `scope.onCleanup(T, ptr, T.deinit)` | Cleanup 必须先于被引用状态释放，查 Scope 实现 |

`createList` 会复制元素；元素是字符串时还复制字符串字节，其他结构体内部指针不深拷贝。不要把临时 struct 字段缓冲区当长期数据。Effect 是副作用入口，派生值优先 memo；不要让 effect 无条件写回自身读取的 signal。

自定义主题查 `zenit.generateTheme` 与 `attachWithOptions(.{ .theme_provider = provider })`。`ui.theme.refs` 是样式 token 引用，主题函数中使用 `t.tokens.*`；不要混淆引用和已解析值。图标默认公共 Lucide，框架语义图标用 `ui.system_icons`，应用图标用 `ui.icons`。
