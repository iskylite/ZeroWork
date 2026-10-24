# Yix/Yss 工作流

先看当前 `examples/hello_button/main.zig`、`view.yix`、`styles.yss` 和生成双胞胎，再读 `docs/YIX_YSS_GUIDE.md`。精确语法查 `docs/YIX_REFERENCE.md` 与 `docs/YSS.md`，不要从 JSX/CSS 想象尚未实现的语法。

## 文件与接口

- `view.yix` → `_view.yix.zig`；`styles.yss` → `_styles.yss.zig`。生成物与源文件一起提交。
- `.yix/.yss` 源文件导入源扩展名，例如 `@import("styles.yss")`；手写 Zig 导入 `_view.yix.zig`。
- 同目录 Yix 和 Yss 不可同 stem；使用 `view.yix` + `styles.yss`。
- 组件从 `ui.widgets` 导入。模板 props 使用 camelCase，如 `onClick`；Zig API 多用 snake_case，如 `on_click`。
- `var count: u32 = signal(0)` 拥有状态，`computed(f(count))` 是只读派生值，模板 `{count}` 保留响应式绑定；事件可写 `onClick={count += 1}`。
- 复用组件区分 Source、Model、Handler，先看对应当前语法与生成输出，不自行发明注解。

## 样式选择

`style` 对应 css；`recipe` 对应 cva；带 `slots(...)` 的 recipe 对应 sva。消费方式如 `S.Panel.of(.{ .emphasis = emphasis })`，slots 再取 `.root/.label`。有限状态用 variant，交互态用 `:hover/:active/:focus`，连续参数用参数化 style。

属性如 `corner-radius` 使用连字符；token 按属性类型解析。先确认当前主题 JSON，示例中的 `counterTitle` 等不是所有 provider 的默认 token。`when` 在 recipe 中组合变体/flag，在参数化 style 中读取参数，不能混用。

## 生成与编译

框架根目录：

```sh
zig build gen-yix
zig build check-yix
zig build test-yix
```

默认本地 `-Dyix-gen=write`，CI check，作为依赖 off；显式选择模式让构建可预测。根目录仅扫描 `src/ui`、`examples`、`tests/yix`。

消费项目可先从 Zenit 根目录手工运行：

```sh
zig build yix -- gen ../myapp/src
zig build yix -- check ../myapp/src
```

随后在消费项目 `build.zig` 用 `dep.artifact("yix")` 建立 host Run step，设置 cwd 为应用根目录，传 `gen` 或 `check` 及自己的源码目录，再使 `exe.step` 依赖它。简单生成步骤可设置 `has_side_effects = true` 保证运行；采用 stamp 缓存时必须登记源文件和双胞胎输入，参照当前 `build.zig` 的 `YixTwins/addYixInputs`。不要只登记目录名便宣称内容变更能失效缓存。

`translateYix` 的缓存输出涉及相邻导入：跨生成文件必须用命名 module 正确连接。普通 app 优先同目录双胞胎。`--watch` 新增文件后重启。仅编辑 app 样式不需要重新生成 Yss schema；改框架样式类型才跑 `gen-yss-schema/check-yss-schema`。

编辑器运行在开发机器上。`zig build dev-tools` 构建本机工具，当前 bundled ZLS 支持 Zig 0.17；设置见 `docs/YIX_EDITOR.md`。补全缺失检查路径/版本；comptime 诊断检查保存时构建；生成失败保留 stderr 诊断。成功 stamp 模式安静，手工 gen 进度在 stdout。
