# 用 Yix 写内置组件

`src/ui/components` 里的内置组件视图用 Yix 书写（`NAME.yix`），样式写在 `styles.yss`。
公共 API（`W.X(.{ … })`、`.mount(scope, cx)`、可作为 `ui.view` 子元素）与手写 Zig 组件一致。
语言本身见 [YIX_REFERENCE.md](YIX_REFERENCE.md)，YSS 见 [YSS.md](YSS.md)，双胞胎生成物的规则见 YIX_REFERENCE §1。

## 组件目录约定

- `NAME.yix`：视图；`styles.yss`：样式配方（引用 `ui.theme.refs` 的 token）；`.yix` 里写 `const S = @import("styles.yss");`。
- `mod.zig` 手写：公共类型、`pub const X = @import("_NAME.yix.zig").X`、测试；**不并入 `.yix`**。
- 双胞胎 `_NAME.yix.zig` / `_styles.yss.zig` 与源一起提交（`zig build` 会自动重新生成，CI 检查）。
- **放哪里**：`styles.yss` 只放视觉——样式、配方、绘制函数（canvas 的 `draw`）、绘制要的数据结构；
  `.yix` 放视图与视图辅助——a11y 语义函数、列表行 key、文案格式化、由参数派生数据（例如 Divider 的形态）；
  `mod.zig` 放公共类型、导出与测试。
- **命名**：样式 / 插槽 / 维度 snake_case、配方 PascalCase、不加 `Style` 后缀（YSS 编译器检查）；组件的文字参数统一叫 `label` 并声明为 `Text`。
- **computed**：只给被多处引用、或要传给样式参数 / 子组件的派生值起名；模板里只用一次的条件直接内联
  （`{if (label.len != 0) …}`，模板表达式同样静态提升）。同一个谓词出现多次时起一个名字复用，别各写一遍。

## 生成与检查

修改组件 `.yix` / `styles.yss` 后运行 `zig build gen-yix`，源码与生成双胞胎一起提交。
`zig build check-yix test-yix` 检查生成物、编译和组件行为；交互改变还应运行相关窗口测试。

手写 `mod.zig` 负责公开 props 和宿主逻辑；生成的视图通过 `ui.view` 挂载，状态与 effect 的生命周期由 scope 管理。
