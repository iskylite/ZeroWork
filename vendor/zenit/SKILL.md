---
name: zenit-app-development
description: 开发、改造和调试 Zenit 桌面应用的入口 skill。适用于新建 app、实现页面和业务交互、消费 Zenit 依赖、使用 Yix/Yss 或 ui.view、接入主题、构建 macOS/Windows 和运行应用 E2E。先核实项目实际 API 与 Zig 版本，再选择组件、管理响应式生命周期并完成验证。单独的框架内部算法审查或 OSS 发布清洗不以此 skill 为主。
---

# Zenit 应用开发

这是仓库内维护的通用 AI 开发指南，供 Claude、Codex 和其他 coding agent 直接读取，不依赖某个 agent 的全局 skill 目录或插件。开发 Zenit app 时先读本文件，再按任务读取下方参考。消费项目可在自己的 agent 入口文件中指向依赖 checkout 的 `SKILL.md`。

目标是交付能构建、能交互、有验证证据的应用功能。先使用公开 API 和已有组件；需要改框架时先证明公开能力不足。

## 先确定项目事实

1. 读目标项目的 `AGENTS.md`、Git 状态、`build.zig.zon`、`build.zig` 和当前页面入口，保留已有修改。区分消费应用与 Zenit 框架仓库。
2. 找到应用实际使用的 Zenit checkout/依赖版本。以该版本的声明、生成代码和可构建例子为准，不能仅依据旧 skill 或记忆猜 API。本文件所在仓库可作为源码参考，但不能替代消费项目实际锁定的依赖。
3. 执行 `zig version`，确认目标平台和 build 选项。当前 Zig 0.17 兼容版本使用 `pub fn main(init: std.process.Init) !void`、`std.heap.DebugAllocator(.{}){}`，App 初始化必须传 `.io = init.io`。优化枚举是 `debug/safe/fast/small`。使用项目要求的工具链，不能默默用旧版本替代。
4. 新建应用先从实际依赖的 `templates/minimal-app` 出发，调整包名、fingerprint 与依赖相对路径；已有应用延续其语言与结构。没有用户偏好时，新页面可优先用 Yix + Yss；小型纯 Zig 改动保持 `ui.view`。不要为此整体迁移已有界面。
5. 先说明本次要实现的行为及验证方式，随后持续实现。常规可逆开发和验证无需反复请求许可。

## 应用实现的核心约束

- 构建使用 `@import("zenit")` 与 `zenit.attach(dep, exe)`；主题使用 `attachWithOptions`。不要手工复制模块依赖图或为同一应用重复实例化 `ui` 模块。
- 单窗口从 `zenit_app.App`、`runWith(mountUI)`、`ui.view.render(scope, cx, view)` 起步；多窗口先读当前 `MultiWindowApp` 例子。普通页面不重写宿主事件循环、GPU 或原生窗口桥接。
- 控件先查 `src/ui/components/mod.zig` 与具体组件 Props/示例，通过 `ui.widgets` 使用。Button、Input、Table、Modal 等已有控件承担交互、键盘与无障碍语义；布局再用 `v.box/row/col` 或 Yix 宿主元素。
- 状态跟挂载 Scope 走。使用 `scope.createSignal`、`createText`、`createList`、`createMemo`，共享页面状态优先 `scope.createState`。`createState` 和 `cx.bindState` 都不自动调用业务 `deinit`；持有资源须注册 `scope.onCleanup`。`cx.bindState` 活到 Cx 销毁，不适合反复挂载页面。
- 视图挂载一次，信号驱动绑定更新。动态文本用 `v.fmt` / Yix 插值；不要只在初次 mount 时 `.get()` 然后误以为会自动刷新。派生值使用 memo/computed/map，避免复制状态。
- `Source(T)` 是只读输入，`Model(T)` 是可写受控输入，`Handler(T)` 是通知。文本输入用 owning `createText`。列表用 `createList`；其中结构体的借用字段仍由调用方保证寿命。读出的 owning slice 不跨下一次写入保存，需要长期保留时复制。
- 回调捕获、列表 row、异步任务和浮层必须服从对应 Scope 生命周期。稳定 row key 使用业务 id；避免栈指针、临时字符串、失效 signal 和销毁后更新 UI。后台 I/O 到 UI 的调度方式先查实际运行时，不猜线程安全。
- 样式放在 `styles.yss` / `styles.zig`，优先主题 token。静态样式 `ui.css`，有限变体 `ui.cva`，多插槽 `ui.sva`，连续值用参数化 style / `v.styleBy`。token 必须存在于当前应用 provider；不要直接照搬示例专用 typography。
- Yix/Yss 维护源文件与生成双胞胎，生成物不手改、不 `zig fmt`。消费应用必须建立自己的生成/检查步骤；Zenit 根目录生成不会扫描消费应用。
- 测试用稳定 `test_id`，覆盖真实的用户操作、结果与键盘路径。为加载、空数据、错误、禁用和长文本等实际相关状态定义可观察行为。

## 按任务读取，避免一次加载全部资料

所有 `docs/`、`src/`、`examples/` 路径都相对上面定位的实际 Zenit 依赖。

| 当前任务 | 先读 | 可选辅助指南 |
| --- | --- | --- |
| 新建应用、纯 Zig 交互、所有权 | [应用入口与状态](docs/skill/zenit-app-development/references/app-patterns.md)，`docs/GETTING_STARTED.md`、`docs/VIEW_DSL.md` | [组件导出](src/ui/components/mod.zig) |
| Yix/Yss 页面、组件接口、生成或编辑器问题 | [Yix/Yss 工作流](docs/skill/zenit-app-development/references/yix-yss.md)，`docs/YIX_YSS_GUIDE.md`；精确语法再查 `YIX_REFERENCE.md` / `YSS.md` | [样式指南](docs/STYLING.md) |
| 控件选型、表格、表单、浮层 | 当前组件 Props、对应 Storybook 示例 | [组件导出](src/ui/components/mod.zig) |
| 主题、变体、布局与视觉还原 | `docs/STYLING.md`、`docs/design-system/TOOLING.md` | [样式指南](docs/STYLING.md)；有 `.pen` 时 `pencil-to-zenit` |
| 平台构建、运行验收、Harness | [构建与验证](docs/skill/zenit-app-development/references/build-validation.md)，`docs/WINDOWS_BUILD.md` / `docs/HARNESS.md` | 写 YAML 用 `zenit-scenario-authoring`；运行已有 scenario 用 `zenit-scenario-toolkit` |
| 框架缺陷导致应用无法实现 | 最小复现、对应源码及已有回归测试 | 用户要求第二意见时使用对应 review 流程 |

辅助指南可能对应较早的 API；仍须核对实际依赖。外部 skill 未安装时，直接使用当前源码和文档继续。发现文档过时，先以源码解决当前任务，按授权修正相关文档；不能用旧指南回退代码。

## 完成条件

- 按实际目标构建，生成检查通过。行为修复先复现再修改，新增针对触发条件的回归验证。
- UI 功能运行真实 app 验证交互；视觉任务还要查看截图或设计差异。只交叉编译不能宣称 Windows 真机验收完成。
- 运行项目要求的 E2E gate；用户要求完整 gate 时不能只用单测替代。Windows 整批验收先传齐程序、脚本和运行依赖，再在目标机器本地一口气执行。
- 交付说明实现了什么、执行了哪些验证、结果和实际未完成项。构建失败必须定位，不能靠放宽验收阈值或删除断言掩盖问题。
- 提交、发布和同步遵循目标项目的仓库指令与用户授权；应用开发任务本身不触发发布或 push。
