# V3 公共组件标准

## 当前入口与真实复用

默认 [组件目录](index.html) 按功能分类，单功能路由如下；不再默认铺开一整页。

| 功能 | 入口 |
| --- | --- |
| 输入与校验 | [inputs](index.html?group=inputs) |
| 选择与下拉 | [choices](index.html?group=choices) |
| 按钮与开关 | [actions](index.html?group=actions) |
| 对话框与浮层 | [overlays](index.html?group=overlays) |
| 工具栏与提示 | [toolkit](index.html?group=toolkit) |
| 状态与容器 | [feedback](index.html?group=feedback) |
| 列表与导航 | [collections](index.html?group=collections) |
| 进度与异步 | [async](index.html?group=async) |
| 通知与追溯 | [notifications](index.html?group=notifications) |

每路由显示输入/状态/事件合同；只呈现适用状态，不给不适用控件虚造全部状态。组件定义仍唯一保存在index.html，由components.js绑定；切换分组不复制样式和控制器。`size=compact`启用有界860×480画布及内部滚动，Modal在画布可见区域居中。

`primitives.css` / `primitives.js` 为本展板与真实设置模板共同消费的基础几何及命中区：32px输入、24px图标动作、30×18小开关。业务选择器的验证/自定义创建由对应业务控制器负责，不用静态样例冒充已接通业务。新功能组件通过现有设置/连接/工作区受控入口组合，禁止再复制相似演示。

本轮细化验证：[记录](../settings/verification/refined/README.md)。下文旧轮次操作保留为历史证据，不等同本轮重新穷举。

[返回设计中心](../index.html#components) · [打开独立组件展板](index.html)

这是独立于业务页面的可编辑、可交互标准展板，待用户确认。样式参数沿用设置 V3：正文 12px、标题 13px、输入高 32px / 圆角 8px、菜单圆角 9px、弹窗圆角 14px。代码为 `index.html`、`components.css`、`components.js`，不依赖业务设置数据。

| 主题 | 内容 |
| --- | --- |
| 输入 | 普通、聚焦、禁用、错误、数值单位、搜索 |
| 选择与下拉 | 普通菜单、搜索与自定义值、分段选择、复选与单选 |
| 按钮与开关 | 主次操作、危险、禁用、加载、图标、开关与滑块 |
| 浮窗与气泡 | 模态确认、非模态浮窗、Tooltip、操作菜单 |
| 工具栏 / Toolkit | 图标命中区、选中态、分隔、提示和标签 |
| 反馈与容器 | 成功/失败、Toast、空态和折叠 |

支持深色、浅色、Sauber；下拉支持键盘方向键、Escape 与 Tab，模态窗使用 dialog 的焦点约束与 Escape 关闭。浮窗点外部关闭。所有动作仅操作展板，不连接真实服务或修改应用数据。

独立展板是通用组件设计标准，模块原稿是业务使用示例；后续变更需同步核对两处。当前不代表已同步 Zenit 原生实现。

## 补全清单与 Zenit 对齐

| 组件族 | 展板入口与可操作状态 | 原生优先映射 |
| --- | --- | --- |
| 输入 | 文本/搜索/数值单位/聚焦/错误/禁用；值可输入 | `Input`、布局容器 |
| 选择 | 单选下拉、搜索过滤、自定义值、无匹配、方向键/Enter/Escape/Tab、复选/单选/分段 | `Select`、`Checkbox`、`RadioGroup`、`Tabs` |
| 操作 | 主次/危险/禁用/加载、图标/开关/滑块；开关状态与展开独立 | `Button`、`Switch`、`Slider` |
| 弹层 | Modal 焦点约束/取消/确认/Escape、Sheet 校验/取消/保存/再次打开保值、非模态详情、tooltip悬浮/聚焦、操作菜单/点外关闭 | `Modal`、`Sheet`、`Popover`、`Tooltip`、`Menu`；窗口 portal |
| Toolkit | 30×30 命中区、选中开关、分隔、窗口内自定义 Tooltip | `Button` + `Tooltip` + 横向布局 |
| 容器反馈 | 空态/折叠/成功/错误/短提示 | `AccordionItem`、`Tag`、`Notifier` |
| 列表与导航 | 页签切主机/文件、主机树折叠/行激活、文件表格多选计数 | `Tabs`、`AccordionItem`、`Table`、`SelectionModel`；大列表 `VirtualList` |
| 异步任务 | 待开始/传输中/暂停/继续/失败/失败续传/完成/取消，失败保留进度身份，Skeleton | `Progress`、`Button`、任务状态模型；原生后台结果回到主线程 |
| 全局通知 | 成功/失败触发 Toast 并记入通知列表；单条移除/全部清除/空态/通知计数 | `Notifier` + 有界通知列表；命令输出归所属终端 |

### 图层与事件规则

独立展板以 `main#component-stage` 为设计画布，弹层按画布与可见视口交集约束定位。下拉/Popover/Tooltip 有边界夹取和空间不足翻转；滚动关闭外部锚点的非模态层，菜单内部滚动保留。Modal 在可见画布内居中；原生实现以窗口 portal 和相应 anchor/viewport padding 复现，不能直接照抄浏览器 fixed 坐标。

### 本轮实际验证

IAB 1280×720 CSS px，DPR 2：API 协议下拉切到 Anthropic；文件页签 → 两项复选 → 计数2；任务模拟失败到40% → 关闭失败模拟 → 继续 → 暂停（进度保留）；连接失败 → 通知计数1 → 通知中心出现对应错误；Popover 测得 x775/y384/240×96.5，位于1280×720可见画布内；确认 Modal 实际打开并取消。相关状态见 [新增组件原型](index.html) 和 [模态窗原型](index.html)。`node --check components.js` 通过。

展板仅是可编辑的组件规范，系统授权/实际网络/文件/剪贴板行为由业务页说明和后续原生实现负责。通用树表格示例不冒充虚拟化的性能验证。本轮已核对当前 Zenit 的 `ui.widgets` 导出，未更换项目工具链或修改原生实现。

补充实测：自定义字体输入 `Custom Mono` → Enter 后触发器更新；Tooltip 聚焦显示，位于视口内（x671/y384/240×46）；Sheet 输入0显示范围错误，改为5保存，重新打开读得5，Escape关闭并回返触发按钮。Sheet 遮罩为可见画布交集（x40/y8/1200×704）。查看 [Tooltip](index.html) 与 [Sheet](index.html) 交互原型；历史视口截图已清理。

本轮实际复测了 Select 单步键盘移动、分段/Tab 方向键、Modal 连续打开后 Esc 的取消语义、Sheet 草稿取消/保存、滑块、任务失败重试与通知列表。860px 评审画布与滚动中浮层均有界；尺寸选择器位于产品外。详细路径、测量和原生 API 差异见 [专项报告](../verification/settings-components-audit.md)。
