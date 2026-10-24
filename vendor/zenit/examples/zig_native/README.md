# zig_native — 只用 Zig 写组件（不用 Yix / YSS）

Yix（`.yix`）和 YSS（`.yss`）是可选的：它们编译出来的就是这里手写的这些 `ui.view` 调用。
喜欢纯 Zig 的话，界面、组件、样式都可以直接写，跑的是同一套运行时，两种写法的组件也能互相使用。

```bash
zig build zig-native       # 构建并打 .app bundle
zig build run-zig-native   # 直接跑
```

## 文件

| 文件 | 内容 |
|---|---|
| `components.zig` | 四个可复用组件，各演示一种常见形态 |
| `styles.zig` | 样式对象：`ui.css` / `ui.cva` / `ui.sva`，以及一个 `styleBy` 函数 |
| `main.zig` | 用这些组件和内置组件拼出界面：任务列表、进度条、受控的优先级步进器 |

## 一个组件的完整写法

```zig
pub const PillProps = struct {
    label: ui.Source([]const u8) = .{ .value = "" },   // 调用方可传值或信号
    tone: ui.Source(S.Tone) = .{ .value = .neutral },
};

pub fn Pill(args: anytype) v.ComponentOf(pill) {
    // coerce：调用方的匿名结构体 → props（普通值包成静态源，信号原样）
    return v.component(pill, ui.reactive.props.coerce(PillProps, args));
}

fn pill(props: PillProps, scope: *ui.Scope, cx: *ui.Cx) anyerror!*ui.Node {
    return v.render(scope, cx, v.row(.{ .style = S.Pill.of(.{ .tone = props.tone }) }, .{
        v.text(.{ .style = S.pill_text }, props.label),
    }));
}

// 使用：Pill(.{ .label = "Zig", .tone = .accent })，tone 也可以是信号
```

组件函数只在挂载时运行一次，之后靠信号做细粒度更新：没有虚拟 DOM，也不重跑。

## 四种形态

| 组件 | 演示 | 关键 API |
|---|---|---|
| `Pill` | 无状态组件 + 变体配方 | `ui.Source(T)` 参数、`S.Pill.of(.{ .tone = 源 })` |
| `Stepper` | 受控值：不传时自持，传信号时双向绑定，改动经回调报出 | `ui.Model(T)`、`ui.reactive.resolveModelFor` → `read` / `propose` |
| `Section` | 插槽：调用方的子元素放进组件内部的指定位置 | `v.slotted`、`v.slotEnd`、`v.slottedParts`；使用处 `v.with(Section(…), .{ … })` |
| `TaskRow` | 多部件配方 + 事件回调 | `S.TaskRow.slot(.root, 变体值)`、`ui.Handler(void)` 参数直接挂到 `on_click` |

## 与 Yix / YSS 的对应

| Yix / YSS | 纯 Zig |
|---|---|
| `pub fn X(label: []const u8 = "") View` | `XProps` 结构体（`ui.Source(T)` 字段）+ `fn x(props, scope, cx) !*Node` + `v.component(x, props.coerce(…))` |
| `label: Text = ""`（文字子元素进 label） | props 里写 `pub const text_child = "label";` |
| `onClick: ?Handler(void) = null` | 字段 `on_click: ?ui.Handler(void) = null` |
| `value: Model(i32) = 0` | 字段 `value: ui.Model(i32) = .{ .local = 0 }` + `resolveModelFor` |
| `children: View` + 模板里的 `{children}` | `v.slotted` + `v.slotEnd(&slot, 容器)` + `v.slottedParts` |
| `var n: i32 = signal(0)` / `computed(…)` | `scope.createSignal` / `scope.createMemo` / `ui.map` |
| `{if (x) …}` / `{for (xs) |x| …}` | `v.show(源, .{…}).fallback(.{…})` / `v.each` / `v.eachWith` |
| `onClick={n += 1}` | `ui.on.update` / `ui.on.set` / `ui.on.bind(scope, ctx, f)` |
| `style card { … }` / `recipe Card { … }` | `ui.css(.{ … })` / `ui.cva(.{ … })` / `ui.sva(.{ … })` |
| `style size($w: ?f32) { … }` | `fn size(w: ?f32, t) BoxStyle` + `v.styleBy(源, size)` |

完整的 `ui.view` 参考见 [docs/VIEW_DSL.md](../../docs/VIEW_DSL.md)，样式见 [docs/STYLING.md](../../docs/STYLING.md)。
