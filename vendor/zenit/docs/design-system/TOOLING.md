# Design System Tokens：生成与 UI 接入

生成器已支持 [v1 声明语法](../DESIGN_SYSTEM_TOKENS.md)：两层声明合并为统一引用、重复路径拒绝、类型检查、模式回退、跨 token 引用和复合材料。生成过程不扫描 Zig/Yix，也不在运行时读取 JSON。

## 使用

```sh
zig build tokens -- check docs/design-system/theme.example.json
zig build tokens -- generate docs/design-system/theme.example.json --out /tmp/theme.gen.zig
zig build tokens -- explain docs/design-system/theme.example.json color.action --mode high_contrast
zig build test-tokens
```

`explain` 同时接受统一消费路径 `color.action` 和声明路径 `semantic.color.action`，显示最终值、源 JSON Pointer、选择的模式分支和引用链。未知 token/mode 返回失败；失败的 generate 保留已有输出，写入成功后通过同目录临时文件原子替换。

输入错误包含文件名、行列、JSON Pointer 和具体原因。行列按源 UTF-8 字节计数。重复消费路径会同时给出第一次声明的 Pointer。JSON Schema 负责编辑器结构提示；生成器另外验证引用存在性、类别、方向、循环、合并冲突和 mode 注册。

## 构建接入

依赖项目的 build.zig：

```zig
const zenit = @import("zenit");
const dep = b.dependency("zenit", .{ .target = target, .optimize = optimize });
const app_theme = zenit.generateTheme(b, dep, b.path("theme.json"), .{
    .target = target,
    .optimize = optimize,
});
zenit.attachWithOptions(dep, exe, .{ .theme_provider = app_theme });
```

生成器使用 host target，产出的模块使用应用 target；生成物留在 Zig 构建缓存。helper 共用依赖包导出的 `zenit_style_values` 模块实例，避免相同结构的 Color 被视为不同类型。

当前实际可用的生成接口：

```zig
const ui = @import("ui");
const theme = ui.theme;
const TOKENS = theme.refs;

const surface = theme.resolve(.color, TOKENS.color.surface, &theme.modes.dark);
const heading_size = theme.modes.dark.tokens.font_size.title;
```

- `refs` 和 `modes.*.tokens` 都是基础与 semantic 合并后的类别树。
- `Token(category)` 是该类别的引用枚举；错误类别不能传给 resolve。
- `Values` 只有模式信息和统一 `tokens`；没有 system、bindings 或默认角色回退。
- `metadata` 提供统一路径、声明来源和 JSON Pointer；引用链解释由 CLI 读取原声明完成。
- 空类别、空 tokens、数字名称、关键字、连字符和嵌套分组都可生成实际能编译的 Zig。

## 样式消费

```zig
const TOKENS = ui.theme.refs;
const heading = ui.css(.{
    .typography = TOKENS.typography.heading,
    .color = TOKENS.color.text,
});
// 当前模式的具体值，用于需要计算的具名样式函数：
const gap = cx.tokens.tokens.space.content_gap;
cx.setTheme(&ui.theme.modes.dark);
```

`css/cva/sva` 共用引用解析，跨类别引用编译失败。`typography` 只用于文本，先展开部分字段，再覆盖显式 text 属性，与属性声明顺序无关。`sva` 支持 box/text slots：视图用 `.of(args).slot`，手动解析文本用 `.Slot(.label).resolveText(...)`。`.fill/.fit` 是布局语法；同名尺寸 token 用 `TOKENS.size.fill` 明确引用。

一个 UI 模块实例只接受一个 provider。重复绑定同一个 provider 合法，绑定不同 provider 会在构建时报错。低层构建可使用 `wireThemeProvider`；通常直接用 `attachWithOptions`。不传 provider 时使用框架默认 JSON。生成模块也仍可通过 `addImport` 独立使用。

仓库 examples 使用独立的 UI/App 模块图绑定 [examples/theme.json](../../examples/theme.json)，不改变库的默认 provider。手写和 Yix Counter 共享样式模块。内置 recipe 和应用样式都通过 `refs` 或 `Values.tokens` 消费同一套材料。内置 recipe 直接依赖约定的 semantic 名称；应用提供这些名称，可用自己的基础 token 定义其值。引用不存在的名称编译失败，不回退旧值。

主题切换重放应用树、独立 overlay 和 portal；同一棵树只通知一次。当前 variant/hover 状态保留，根树之间用代次校验跳过通知期间被销毁的树。普通手动构造的样式快照仍是快照；此工作没有添加每帧主题轮询。

## 当前边界

元数据始终生成；可选元数据开关、局部主题作用域和响应式窗口条件不在本次范围。自定义 `$mode` 是主题模式，不是组件状态或断点规则。

## 验收

`test-tokens` 运行解析/生成/默认材料测试，实际编译四份生成 provider，并要求错误类别的引用编译失败。覆盖包含 OOM 扫描、模式回退穿透引用、跨模式并集假环、1,024 条引用链、类型/范围/重复声明、源码诊断及确定性生成。默认 JSON 与测试专用快照逐值比较；该快照不进入生产模块；`test-yix` 另验证应用自定义 token、typography 覆盖顺序、sva 的模式/hover/variant 联动，以及独立 overlay/portal 通知。`test-css-errors` 验证类别不匹配和 box 使用 typography 的编译错误。
