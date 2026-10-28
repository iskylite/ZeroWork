# 设置 V3 原稿

## 功能组件入口

以下是实际设置模板的受控隔离路由，复用同一settingsReview状态和事件，供功能组件目录组合；没有复制一份独立示例。

| 组件 | 入口 | 合同 |
| --- | --- | --- |
| 设置导航 | [settings-navigation](index.html?component=settings-navigation) | activePage/query/dirtyPages → navigate/search；左右独立滚动 |
| 保存事务 | [settings-transaction](index.html?component=settings-transaction) | draft/baseline/errors/saving → validate/save/revert；失败保稿 |
| 主题选择 | [theme-picker](index.html?component=theme-picker) | themes/selectedTheme → preview/import/delete |
| 字体与排版 | [font-settings](index.html?component=font-settings) | family/size/lineHeight/cursor → change/validate |
| 模型条目 | [model-row](index.html?component=model-row) | providerId/modelId/metadata/test/default → test/edit/remove/setDefault |

可以追加`size=compact`、`theme=...`、`saveFailure=1`等已有受控场景参数。普通设置与隔离路由共用`.settings-viewport`居中容器、左菜单/右正文独立滚动、固定头脚和components/primitives基础几何。整机集成模式不重复计算外层居中，由宿主负责16px边距。

本轮验证与尺寸见[细化记录](verification/refined/README.md)。

状态：**待用户确认**。入口：[完整设置](index.html)。

## 主要场景

| 场景 | 入口 |
| --- | --- |
| 外观与主题 / 12 个主题 / 卡片内横向滚动 | [主题](index.html?page=appearance) |
| 字体、光标三种形状与终端预览 | [字体与排版](index.html?state=font) |
| 背景开关、选图、适配、对齐与效果预览 | [背景](index.html?state=background) |
| 快捷键录制与冲突提示 | [快捷键](index.html?page=keys) |
| SSH、重连、SOCKS5 与认证默认值 | [SSH 与网络](index.html?page=ssh) |
| 传输连接、SFTP 引擎与下载默认值 | [文件传输](index.html?page=transfer) |
| 新安装的 Provider 空态 | [AI 辅助](index.html?page=ai) |
| 多 Provider / 多模型的滚动演示数据 | [已有配置场景](index.html?state=ai-populated) |
| 模型清单仅返回 ID、能力缺失 | [能力缺失](index.html?state=ai-populated&apiScenario=partial) |
| 不支持模型清单，允许手动配置 | [不支持清单](index.html?state=ai-populated&apiScenario=unsupported) |
| 获取清单失败及模型测试失败 | [失败场景](index.html?state=ai-populated&apiScenario=error&testScenario=error) |
| 内置协议与权限说明 | [协议插件](index.html?page=plugins) |
| 事件通知与勿扰 | [通知](index.html?page=notify) |
| 位置、会话记录、导出与清理 | [数据与日志](index.html?page=data) |
| 保存失败，保留未保存输入 | [保存失败](index.html?saveFailure=1) |

`state=ai-populated` 只在明确打开该演示入口时载入样例，不能成为新安装的默认配置。

## 视觉与几何

- 延续 V3 的紧凑字号、靛蓝主操作、轻凹输入与固定操作栏；按本轮用户要求使用独立设置卡片。
- 标准面板宽 900 个逻辑像素，最大高 640；根据可用视口收缩。固定顶栏、分类导航和底部操作，中间内容有界滚动。小视口内仍须检查可达性，不能把大图整体缩放当作适配。
- 卡片圆角 11px、常规输入与按钮 8px、统一选择菜单 9px、选项 6px、弹窗 14px。卡片标题按钮继承圆角并受标题区裁切，覆盖悬浮/焦点/点击状态。
- 普通输入高 32px；搜索图标、输入及快捷键共享同一个聚焦表面，内部输入透明。
- 主题在原卡片内浏览；缩略图高 42px，含 12 种可切换配色。不会再弹出独立主题库。
- 所有下拉使用同一 `choiceControl`。字体/模型支持搜索与自定义输入；其余选项保留同样的菜单、选中反馈与键盘规则。光标形状是带图示的互斥按钮。
- Provider 列表最大高 450px，每个 Provider 的已配置模型列表最大高 190px，分别内部滚动；下拉清单也有界滚动。

## 折叠、启用与保存

折叠只改变展示，不改变开关或配置值，不制造未保存更改。功能开关不负责折叠；关闭背景后仍可编辑参数，开启后生效。尝试启用未配置完整的 Provider 时，展开并就近指出缺失项。

输入框与折叠按钮是不同的命中区域。修改名称、打开菜单或添加模型不能触发父级折叠。跨分类修改共用保存/撤销；保存失败保留输入，放弃模型编辑有确认。

## Provider 与模型契约

1. 新安装时 Provider 列表为空；只有用户新增或加载历史配置才存在条目。一个条目是一个有独立名称、地址和凭据的 Provider，`API 协议` 只是该 Provider 的属性。多个 Provider 可以使用同一协议。
2. 先填写连接信息，再点击“获取模型清单”；也可以先添加模型，在表单内获取。加载、请求失败、接口不支持清单、空清单都提供明确状态和手动添加路径。
3. 模型 ID 从统一的可搜索下拉选择，也允许手动输入。选择后仅带入响应实际提供的上下文、推理、识图与推理档位信息。
4. 未返回的能力是“未知/待补充”，不能用 `false` 冒充“不支持”。用户补填后标记为手动设置；已返回的值也允许校正。模型 ID 同一 Provider 内不得重复，上下文必须是有效正整数。
5. “测试模型”提供测试中、通过、失败与重试；可在添加表单和已配置模型行中调用。改变地址、凭据、协议、模型或相关配置后，旧测试结果失效。测试通过不自动启用 Provider。
6. 第一项模型成为该 Provider 的默认模型，默认 Provider/模型删除仍需要有效替代项。协议不是默认 Provider 的替代身份。
7. 连接变化后清单失效，异步旧响应不能覆盖新配置。测试结果与包含凭据的临时请求签名只保存在内存，不纳入持久化或脏状态。

## 演示与真实实现的边界

这是设计原稿，不是生产设置页。顶部评审栏属于稿件工具，不属于原生产品界面。

- 清单与模型测试使用明确的模拟响应，没有真实网络请求；顶部可切换正常、缺失、空、不支持和失败场景。不能把这些“通过”结果作为实际模型可用性的证据。
- 不是所有协议或网关都会在模型清单里返回全部能力，缺失项必须保留手动补填。原生实现应据具体接口响应映射，不硬编码所有模型的能力。
- 演示 Provider、模型 ID 与配色用于观察状态，不代表真实供应商或已配置服务。默认入口没有这些 Provider。
- 浏览器本地存储只用于本效果稿；API Key、测试状态和请求签名不持久化。不会写入应用配置或钥匙串。
- 主题导入解析简化 JSON/TOML 设计字段，日志导出生成纯 fixture JSON，清理只演示确认与异常反馈，不执行真实应用操作。背景选图使用本地临时 URL，重载后需重新选择。

## 验收重点

浏览器验收至少走通：空态、新建同协议的多个 Provider、模型清单获取与失败、选择模型带入能力、未知能力补填、手动模型、测试通过/失败/失效、多 Provider/模型滚动、保存/重载/撤销，以及三基础主题、额外配色、菜单键盘行为和圆角。

原生落地时必须再验证真实接口、凭据安全、原生输入法/焦点/滚动/文件对话框；本轮不据浏览器结果宣称 Zenit UI 已完成。

## 完整功能对照与原生映射（2026-10-25 补全）

本轮逐项对照 `src/config/settings_pages.zig` 的 **52 个标量字段**、`src/config/settings_parts/`、`settings_ai_draft.zig` 与 `settings_controller.zig`。52 项均有入口；背景 `enabled/path/fit/transparency` 使用带前缀的展示键，`alignment_x/y` 合并成九宫对齐，`completion.enabled` 显示为应用命令补全。复合编辑器（Provider / 模型、快捷键、插件偏好）另行覆盖。

| 分类 / 入口 | 可见功能与关键状态 | 事件与后续原生组件 |
| --- | --- | --- |
| 外观与主题 | 12 内置主题、JSON/TOML 简化导入、无效/重名反馈、内置/使用中主题删除保护、自定义主题删除确认；背景开关/选图/解码失败/清除/适配/对齐/透明度/模糊；字体/字重/字号/行高/光标/时间戳/补全/高亮/侧栏偏好 | `Input`、`Select`、`Slider`、`Switch`、`AccordionItem`、系统文件选择；预览改变草稿，保存生效 |
| 快捷键 | 27 项，其中 25 可录制、2 项保留；组合录制/重复冲突/保留键校验/解除绑定/恢复默认/取消 | `Button`、`Modal`、键事件；录制不直接提交全部配置 |
| SSH 与网络 | 保活/超时/TERM/压缩；自动重连/次数/间隔/缓存；SOCKS 地址端口；OTP/TOTP | 输入数值范围、依赖禁用、`Select`/`Switch`；新连接使用保存值 |
| 文件传输 | 独立连接/共享限速、窗口/分块/并发、续传/校验、目录/冲突策略 | `Input`、`Switch`、`Select`；运行任务保留启动时快照 |
| AI 辅助 | Provider CRUD/协议/地址/Key 可见性/启用门控；清单正常/空/失败/不支持/能力缺失；模型添加/编辑/重复/默认保护/测试失效/成功/失败详情；权限/身份隐藏/附件限制/默认项/错误入口 | 模型行 **44px 单行**：名称、参数、能力、状态同排，右侧操作；`Tag`/`Button`/`Tooltip`、`Modal`、`Select`、`VirtualList`（大列表） |
| 协议插件 | 3 内置协议身份/版本/权限只读；KVM/RDP/VNC 未来页面入口；合成网格动态偏好示例位于产品窗外评审区 | `AccordionItem`、`Tag`、`Tooltip`、标准字段控件；不提供热安装市场 |
| 通知 | 四类事件、Bell、非活跃圆点、跨午夜勿扰时段；系统权限允许/拒绝/系统总开关关闭；测试通知 | `Switch`、`Input`、`Notifier`；权限模拟按钮在窗口外的评审工具栏 |
| 数据与日志 | 配置/主机/缓存/日志/钥匙串/权限位置；配置目录入口；凭据可用/缺失/访问拒绝；缓冲/快照/保留/导出格式；诊断 fixture 导出；清理范围确认/活动会话阻塞/存储失败/重试 | `Button`、`Modal`、系统 SDK；本稿只生成诊断示例，不触碰真实数据 |
| 全局事务 | 全分类共享草稿；搜索/无匹配/折叠/依赖；保存/失败保留/并发冲突保草稿并重试；撤销/恢复默认确认；关闭取消/放弃并关闭 | `Modal`、`Input`、`ScrollArea`、配置字段合并；恢复默认保留 Provider/主机/凭据 |

### 图层边界

`.settings-window` 是设置应用区域。模态遮罩、Modal、统一选择菜单、Toast 和自定义 Tooltip 均按该区域的 `getBoundingClientRect()` 定位，页面滚动/视口变化/分类切换/评审说明展开时重新测量。菜单在空间不足时向上翻转，Toast 固定在所属窗口内部底部；浏览器默认 title 提示替换为窗口内 Tooltip。评审工具与模拟开关在窗口外。

### 新增状态入口

- [保存冲突](index.html?saveConflict=1)：修改任意项 → 保存 → 取消保留草稿，或“保留草稿并重试”完成本地效果稿保存。
- [通知权限](index.html?page=notify)：展开事件提醒，窗口外选择权限场景 → 测试通知。
- [清理与凭据异常](index.html?page=data)：窗口外选择场景 → 检查凭据状态，或展开导出与清理 → 确认清除；阻塞/错误在原确认窗内保留并可重试。
- [未来协议与插件偏好](index.html?page=plugins)：展开协议扩展；进入 KVM 原型，或切换显示合成网格后保存。

### 本轮实际点击验证

Codex IAB，1280×720 CSS px、DPR 2、100%：八个分类及全部 24 张设置卡片逐项展开；模型行实测 44px 高（同一行三个文本中心点对齐）；模型测试失败 → 查看错误详情 → 关闭；模态遮罩与设置窗口矩形一致（x100/y121.5/1080×560）；并发冲突 → 保留草稿并重试实际保存成功；快捷键解除 → 恢复默认 → 使用；通知拒绝 → 测试提示；有活动会话 → 清理确认被阻塞；钥匙串缺失 → 详情；未来插件卡片与网格开关产生待保存更改。`node --check app.js` 通过。

状态通过[设置 HTML 原型](index.html)中的分类及评审控件查看；历史截图已清理。

### 明确保留的实现边界

- 效果稿中的系统授权、钥匙串、Finder、真实接口、真实清理、真实配置并发均是本地状态模拟。迁移配置目录当前没有原生可编辑入口，原型保留只读位置与“打开目录”，未发明额外迁移流程。
- 主题文件支持 JSON 的 `name` 与 `colors`，或 TOML 的 `name` / `[colors]`。支持 `bg、fg、accent、terminal、cursor、panel、card、well、muted、good、warn、danger` 的六位十六进制颜色；未知字段明确拒绝。导入色应用到对应界面与终端预览，按钮动作色由 accent 派生以保证白字可读。自定义主题仅在当前页面管理，跨模块注册与持久化须原生主题 registry 接入。
- 本轮新增异常路径均有真实 HTML 状态和事件；不将仅有文字描述的未实测分支写成“已逐项实测”。本轮实际通过浏览器文件选择器测过有效/无效/重名主题和背景图片/错误类型；所有快捷键组合、损坏图片解码与原生 IME 未逐一验证。
- 原生组件/API 以当前 `vendor/zenit/src/ui/ui.zig` 与 `components/mod.zig` 为准；已核对上述导出，项目 Zig 0.17.0。本轮不改原生代码。

快捷键基准已对齐当前 `src/config/keybindings.zig`：补全 `⌘;`、采纳 `→`（只读）、AI `⌘J`、广播 `⌘⇧I`。此前效果稿保存的四项旧默认值按 revision 2 迁移；其他自定义键值保留。

补充实测：保存中状态可见并锁定设置操作，保存失败后草稿及重试按钮保留；数据存储失败保留原确认窗；分类切换后遮罩边界再次测得与应用窗口一致（x100/y132/1080×560）。

## 本轮逐项核验补充

标准面板 900×640；最小窗口内面板 828×432。评审尺寸控件位于产品窗外。输入 32px、普通图标按钮 24px、紧凑开关 30×18 / 滑块 14px。导入主题、字体请求值与实际回退、24 卡片、模态焦点和紧凑模型单行条目的实测见 [专项报告](../verification/settings-components-audit.md)。
