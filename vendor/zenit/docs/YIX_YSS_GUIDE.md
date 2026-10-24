# Yix / Yss 开发指南

本指南对应 Zig **0.17.0** 兼容分支。Yix 写组件结构、状态和事件；Yss 写样式、变体和插槽。两者在构建时生成普通 Zig，不需要运行时解释器。

完整语法见 [YIX_REFERENCE.md](YIX_REFERENCE.md) 与 [YSS.md](YSS.md)，编辑器设置见 [YIX_EDITOR.md](YIX_EDITOR.md)，Windows 构建见 [WINDOWS_BUILD.md](WINDOWS_BUILD.md)。

## 先跑现有例子

在仓库根目录：

```sh
zig version
zig build dev-tools
zig build check-yix
```

macOS 运行最小例子：

```sh
zig build run-hello-button
```

Windows 运行共享 Storybook，其中组件已经包含 Yix/Yss：

```powershell
zig build windows-arm64-storybook -Dwindows-arch=x86_64 -Dgpu-backend=d3d12 -Doptimize=fast
if ($LASTEXITCODE -ne 0) { throw 'Storybook build failed' }
.\zig-out\bin\zenit-windows-storybook.exe
```

仓库的 `hello-button` / `run-hello-button` 是 macOS 示例入口，不要把 `.app` 命令直接用于 Windows。Windows UI 代码的 Yix/Yss 生成流程相同，区别在宿主运行时和后端。

## 文件分工与导入

以 `examples/hello_button` 为例：

| 文件 | 维护方式 | 内容 |
| --- | --- | --- |
| `main.zig` | 手写 | 创建 App、传入 I/O、挂载组件 |
| `view.yix` | 手写 | HelloButton 的状态、事件、视图 |
| `styles.yss` | 手写 | 样式与 Panel 配方 |
| `_view.yix.zig` | 生成并入库 | 组件的普通 Zig 实现 |
| `_styles.yss.zig` | 生成并入库 | `ui.css` / `ui.cva` / `ui.sva` 等实现 |

源文件之间写 `@import("styles.yss")` 或 `@import("card.yix")`；编译器改写成生成文件名。手写 `.zig` 不经过这一步，必须导入 `@import("_view.yix.zig")`。不要手改或 `zig fmt` 生成文件；源码和生成物一起提交。

同目录的 `.yix` 与 `.yss` 不能使用相同 stem，例如 `card.yix` 与 `card.yss`；样式文件使用 `styles.yss`。

## 状态、模板和事件

下面是仓库正在使用的 `examples/hello_button/view.yix`：

```yix
const ui = @import("ui");
const Button = ui.widgets.Button;
/// Stylesheet (styles.yss): JSON token reference + app recipe S.Panel, separated from interface
/// structure.
const S = @import("styles.yss");

fn emphasisOf(n: u32) S.PanelEmphasis {
    return if (n > 0) .highlight else .neutral;
}

/// Click +1; after clicked, count panel switches to highlight variant (cva variant directly
/// receives computed source).
pub fn HelloButton() View {
    var count: u32 = signal(0);
    const emphasis = computed(emphasisOf(count));
    return (
        <col style={S.root}>
            <text style={S.title}>Hello, zenit!</text>
            <Button variant={.primary} size={.md} onClick={count += 1}>Click me</Button>
            <box style={S.Panel.of(.{ .emphasis = emphasis })}>
                <text style={S.counter_label}>Clicked {count} times</text>
            </box>
        </col>
    );
}
```

- `signal(0)` 建立组件拥有的状态；模板直接写 `{count}`，不需要手写订阅或 `.get()`。
- `computed(...)` 随实际读取的响应式依赖重新计算；它是只读值。
- `onClick={count += 1}` 是事件语句；参数名使用 camelCase，生成的 Zig 字段使用 snake_case。
- `Source(T)` 表达只读输入，`Model(T)` 表达可写受控输入，`Handler(T)` 表达回调。调用方传信号可建立双向绑定；组件应通过 Model 写值，通过 Handler 通知。
- UI 组件从 `ui.widgets` 取得；宿主元素如 `<box>` / `<col>` / `<text>` 用于组成视图。控制流、生命周期、ref 和插槽见语言参考。

## Yss 样式与变体

同一例子的 `styles.yss`：

```yss
//! JSON token reference + component recipe, separated from interface structure (view.yix).
//! Auto-replay on theme / variant change.
const ui = @import("ui");

style root { width: fill; height: fill; direction: column; gap: space400; padding: space1000; background: bg-primary; align-items: center; justify: center; }
style title { typography: counterTitle; color: fg-primary; }
style counter_label { font-size: lg; color: fg-secondary; }

/// Count panel: after clicked, switches to highlight
recipe Panel {
  base { padding: space200 space400; corner-radius: md; }
  variant emphasis = neutral {
    neutral { background: bg-secondary; }
    highlight { background: bg-tertiary; border: thin accent; }
  }
}
pub const PanelEmphasis = Panel.Dim(.emphasis);
```

`style` 对应 `ui.css`；`recipe` 对应 `ui.cva`；`recipe Name slots(root, label)` 对应 `ui.sva`。`mixin` 在编译期展开，适合共享属性块。

配方通过 `S.Panel.of(.{ .emphasis = emphasis })` 消费；这里传 computed 源，状态变化会更新样式。插槽配方使用 `.of(args).root` / `.label` 等具体 slot。连续尺寸等开放值用 `style name($gap: f32) { gap: $gap; }`，在模板用 `.of(.{ .gap = source })`。

属性使用 `corner-radius` 等连字符名。token 名按属性类别解析，使用当前主题的值；`bg-primary` 等是本例使用的 token，并非任意应用都必须有的名字。应用主题由 JSON provider 绑定，详见 [design-system/TOOLING.md](design-system/TOOLING.md)。`{Zig 表达式}` 是需要计算时的入口。

`:hover` / `:active` / `:focus` 等表示节点交互状态；recipe 内的 `when` 组合变体或 flag，参数化 style 内的 `when` 则读取参数。不要将这两种条件混用。

## Zig 启动入口

`main.zig` 导入生成组件，用公开 View API 挂载：

```zig
const std = @import("std");
const ui = @import("ui");
const App = @import("zenit_app").App;
const HelloButton = @import("_view.yix.zig").HelloButton;

fn mountUI(cx: *ui.Cx, scope: *ui.Scope) anyerror!*ui.Node {
    return ui.view.render(scope, cx, HelloButton(.{}));
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const app = try App.init(gpa.allocator(), .{
        .io = init.io,
        .window = .{ .width = 640, .height = 480, .title = "Hello Button" },
    });
    defer app.deinit();
    try app.runWith(mountUI);
}
```

示例构建还为 `ui` 绑定了 `examples/theme.json`。拷贝样式到独立应用时，应一并绑定兼容的主题；否则示例专用 token（如 `counterTitle`）可能不存在。

## 生成、检查与独立应用

| 操作 | 命令或默认行为 |
| --- | --- |
| 重新生成仓库全部双胞胎 | `zig build gen-yix` |
| 检查缺失、过期、手改和孤儿生成物 | `zig build check-yix` |
| 编译时自动生成 | 本地 `-Dyix-gen=write` 默认 |
| CI 只检查 | 有 `CI` 环境变量时默认 `check`，建议显式 `-Dyix-gen=check` |
| 禁止构建改写源树 | `-Dyix-gen=off`；作为 Zig 依赖时默认 off |
| 监听已有源码 | `zig build hello-button --watch`；新增源文件后重启 watch |
| 翻译单个源文件 | `zig build yix -- INPUT.yix OUTPUT.zig`，Yss 同样可用 |

仓库的批量生成范围是 `src/ui`、`examples`、`tests/yix`，不会自动扫描另一个应用的 `src`。在 Zenit 根目录可先手动处理消费项目：

```sh
zig build yix -- gen ../myapp/src
zig build yix -- check ../myapp/src
```

消费项目要在自己的 `build.zig` 中使用 `dep.artifact("yix")` 建立 host Run step，再让应用编译依赖该步骤。推荐生成同目录双胞胎，保留相对导入；`translateYix` 生成到缓存时，需要用命名 module 连接其他生成模块，不能假定缓存目录旁边有 `styles.yss`。

Yss 属性 schema 是框架生成物。仅修改应用样式无需重新生成 schema；修改 `BoxStyle` / `TextStyle` 等框架类型后运行 `zig build gen-yss-schema`，再运行 `zig build check-yss-schema`。

## 编辑器与验证

构建 `dev-tools` 后，安装扩展并打开项目根目录。Yix/Yss 与 ZLS 均在编辑器所在机器运行；在 Mac 上交叉编译 Windows GUI 不会把本机编辑器工具变成 Windows 程序。

保存可生成双胞胎并运行 `yix.buildOnSave` 指定的构建。Windows 开发建议将该命令设为带架构和 D3D12 参数的 Storybook 目标，完整配置见 [YIX_EDITOR.md](YIX_EDITOR.md)。

```sh
zig build check-yix check-yss-schema
zig build test-yix
zig build dev-tools yix-lsp-smoke
```

`test-yix` 同时包含 Yix/Yss 编译器、生成 UI、LSP 映射及协议回归；`yix-lsp-smoke` 使用真实的 bundled ZLS。当前 UI/runtime 测试入口主要面向 macOS；Windows 运行验收使用上一节专用目标和 [整批验收](WINDOWS_BUILD.md)。

常见问题：没有 Zig 补全先检查 `zenit-zls` 路径与版本；有语法诊断却没有 comptime 类型错误先检查保存时构建；主题 token 不存在先检查应用 provider；生成物过期改源码后重新生成，不手改双胞胎。
