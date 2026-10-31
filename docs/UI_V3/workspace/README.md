# 工作区 V3 · 本地 ZSH / SSH / SFTP

> 当前评审：。本轮替代下文与其冲突的侧栏、会话、气泡、连接页与 KVM 展示规则；待用户确认后再落地 APP UI。
[返回设计中心](../index.html) · [打开交互原稿](index.html) · [公共组件标准](../components/index.html) · [设置 V3](../settings/index.html)

本目录是新的可编辑 HTML/CSS/JS 设计原稿，供确认交互后映射到原生 zenit。**不是原生功能完成声明**。所有主机、命令输出、认证、AI、文件、传输与异步结果均为固定示例或本地模拟；不连接真实服务器，不读取或保存密码，不操作实际文件。

## 主机行布局补全 · 2026-10-30

原型原本已有路由图标及直连 `0`（`hostRouteLabel`），此次故障来自原生实现的 `hops > 0` 条件及固定 72px 操作占位。此次补全长名称、窄侧栏和悬停的可复现场景，以下规则作为该区域的当前基准。

- SSH / SFTP 默认显示路由图标及跳板数，直连为 `0`，数字不表示分组主机数量。
- 默认右侧路由区 36px；三个操作按钮隐藏时不占位。悬停或键盘焦点进入该行时，保留路由图标和跳数，并在右侧增加 72px 操作区；离开且焦点移出后仅收起操作区。路由信息与操作按钮不得重叠。
- 名称保持单行，获得图标、状态及必要间距之外的可用宽度；仅在实际不足时显示省略号。SSH 不重复显示协议标签；SFTP 保留标签。
- 完整名称、地址及路径由原有主机提示框显示；操作仍为连接、复制配置、编辑配置，不新增交互。
- 侧栏检查宽度为 220 / 238 / 480px。`hosts=layout` 仅替换本地演示名称及分组，复用 `renderHosts` 和原有交互；`sidebar-width` 用于固定检查宽度，普通入口保持自动宽度逻辑。

| 检查场景 | 可编辑原型入口 |
| --- | --- |
| 窄侧栏、直连与多跳、长中英文名称 | [220px](index.html?hosts=layout&sidebar-width=220&mode=local) |
| 常规宽度 | [238px](index.html?hosts=layout&sidebar-width=238&mode=local) |
| 宽侧栏 | [480px](index.html?hosts=layout&sidebar-width=480&mode=local) |
| 最小窗口展开侧栏 | [860×480](index.html?hosts=layout&sidebar-width=220&size=compact&sidebar=expanded&mode=local) |
| 独立主机组件，同一 renderer | [主机组件](index.html?component=host-sidebar&sidebar=expanded&hosts=layout&sidebar-width=220) |

悬停名称可查看完整身份；按 Tab 可检查焦点状态及操作按钮。三主题通过页面已有主题按钮切换。

已用浏览器检查 220px 深色、238px 浅色、480px Sauber 和 860×480 展开侧栏；跳数均为 `0 / 1 / 2 / 0 / 0`。220px 下两个短名称完整显示，长名称按可用宽度省略；480px 下全部名称完整显示。操作区为 72px，默认路由区为 36px；完整名称提示已显示。悬停保留路由的修正同步到原生布局。

## 直接进入

| 场景 | 交互入口 | 状态入口 |
| --- | --- | --- |
| 本地 ZSH · 展开侧栏 | [local](index.html?mode=local) | [展开](index.html?mode=local) |
| 本地 ZSH · 折叠侧栏 | [local / collapsed](index.html?mode=local&sidebar=collapsed) | [折叠](index.html?mode=local&sidebar=collapsed) |
| SSH 在线 | [ssh](index.html?mode=ssh) | [在线](index.html?mode=ssh) |
| SSH 组与内置命令流 | [group](index.html?mode=group) | [组页](index.html?mode=group) |
| SFTP 双栏工作区 | [sftp](index.html?mode=sftp) | [双栏](index.html?mode=sftp) |
| SSH 认证 | [auth](index.html?mode=auth) | 可直接输入任意演示文本并确认 |
| SSH 连接失败 | [failed](index.html?mode=failed) | 重试或关闭失败页签 |
| 空工作区 | [empty](index.html?mode=empty) | 本地 / 快捷连接入口 |
| 无主机侧栏 | [empty / hosts=empty](index.html?mode=empty&hosts=empty) | [空态](index.html?mode=empty&hosts=empty) |
| 有主机侧栏 | [local](index.html?mode=local) | [展开搜索](index.html?mode=local) |

窗口基准：**1440 × 900 CSS / 逻辑像素**，对应 `src/main.zig` 的应用默认窗口。评审工具位于窗口外；页面最小宽度 1488px，较小浏览器通过滚动查看，不缩小字体或控件。设置弹窗不随工作区放大。

公共参数：`theme=dark|light|sauber`；`sidebar=collapsed`。页面上方的场景选择、主题按钮和重置按钮属于**设计评审工具**，不计入产品窗口。页面下方始终标记本地模拟边界。

以仓库根目录为静态服务器根目录，访问 `http://127.0.0.1:5179/docs/UI_V3/workspace/index.html`，以便读取共享应用图标和 SVG 资源。本模块没有打包、安装依赖；也可以从 `index.html` 本地打开。设置、设计中心、组件链接均为相对路径。

## 页面与功能覆盖

### 公共工作区

- 顶栏：会话页签、关闭、新建本地或快捷连接、右键会话菜单；组成员只在组页签内呈现，不再同时露出成员独立页签。
- 左栏：展开 / 折叠，主机名称与地址搜索，服务器组折叠，连接与终端组入口，新建连接；折叠后仍保留可聚焦图标及名称。
- 右上功能区：快捷连接、全局传输管理器、AI 顶部浮窗、现有设置稿链接。图标有中文标签、hover / keyboard focus tooltip。
- 全局通知：右上 toast，关闭动作；应用命令结果不借用 toast 替代终端记录。
- 状态浮卡：身份 / 进程 / cwd、通信链路、SOCKS、全局主题、组广播及传输摘要。浮卡锚定触发器，按 APP 内容区域夹取，Esc / 点击外部关闭。编码、网格只读；延迟融入连接状态按钮与详情。
- 弹窗：关闭与取消，Esc，点击遮罩关闭，Tab 焦点循环，关闭后尝试回到触发器；字段错误不关闭弹窗。
- 三主题沿用设置 V3 tokens；正文、终端等宽排版和原型外评审工具分开。

### 本地 ZSH

- Shell 记录、内置命令、当前草稿共用一个可滚动文档。
- `pwd`、`ls`、`git status`、`echo`、`clear` 等只给本地演示输出；其他输入明确标记未执行真实命令。
- 行首 `@` 候选，过滤、上下选择、右箭头采纳、Enter；有参数的命令采纳后补空格并继续编辑。输入法合成中 Enter 不提交执行。
- 本地目录 / 登录 Shell / 进程身份、全局主题；SSH 转发入口显示本地不适用说明，上传下载内置指令不出现在本地候选。
- 搜索、只读历史回放、组加入 / 退出、new / dup、AI 上下文示例。

### SSH

- 在线、连接中、认证与连接失败；重试连接进入认证演示，失败页签可直接关闭。
- SSH 身份与链路浮卡、SOCKS 关闭 / 开启 / 配置及局域网暴露确认；配置仅改变演示状态。
- `@grp`、`@pin`、`@sync on|off`、`@ts` 自动切换、`@theme`、`@log`、`@new`、`@dup`、`@up`、`@dl`、`@ai`、`@help`。
- 同组 new / dup 一次新增一个目标会话，保持原组与来源焦点。来源显示与指令关联的简要 pending / success；新目标的连接详细过程只在目标 pane。new 使用默认目录，dup 继承来源目录。
- 广播确认列出来源、接收者、有效目标数，零目标禁用开启。批准快照冻结来源与接收集合：切焦点不改变来源，新增 / 重连成员不静默纳入，断线或移出成员不接收。运行态底栏参与数包含来源，明细有效接收数排除来源。

### SFTP

- **左本地、右远端双栏**；两侧独立路径、返回 / 上级、面包屑、路径编辑、筛选、刷新、名称 / 大小 / 日期排序、选择与目录缓存。
- 单选、checkbox / Cmd / Shift 多选、全选，双击目录进入；文件双击打开只读演示预览。
- 右键 / 更多菜单：上传或下载、重命名、属性、删除；创建目录、名称校验、删除确认。所有变更只作用于当前浏览器演示数据。
- 上传明确取左侧选择，下载明确取右侧选择；两侧选区互不覆盖，多文件保持多项。
- 上传 / 下载确认包含来源、目标目录、下载另存名、断点续传、校验与完成提醒；选择目录替换为示例路径。
- 可勾选同名冲突，演示取消 / 跳过 / 另存为 / 保留两份 / 覆盖二次确认；进入全局传输管理器查看队列、进度、暂停、继续、失败、重试、取消、完成与定位。
- SFTP 不提供终端输入广播；底栏仍有统一广播、链路、转发、传输区，按当前会话能力显示说明及可用动作。

## 内置指令与输出：新呈现契约

`.terminal-scroll` 是文档流，Shell 行、`.app-command` 记录、下一条输入行按顺序排列。`.app-command` **没有 absolute / fixed 定位**，不覆盖旧终端输出，不作为内容区底部横幅。Shell 输出与 app-command 是不同来源的数据，不能把应用文本注入远端 VT 原始字节流。

| 部分 | 视觉和行为 |
| --- | --- |
| 命令行 | 沿用 12px Menlo / Monaco 终端基线；accent 命令文字与细左标线，轻 tint 背景；小型 ZeroWork 来源标记与时间 |
| 成功结果 | 与该命令同一记录，绿色确认标记、清晰结果，保留在后续 Shell 行之前 |
| pending | 同条记录的进度状态，创建目标后更新这一条，不再 append 一套全局连接日志 |
| 参数错误 | 红色低强度标记、具体原因与用法；保留可修改草稿，修正后形成下一次执行记录，不覆写旧诊断 |
| 异步身份 | 原生命令模型需稳定 command ID、来源 SessionHandle、目标 SessionHandle / operation；完成后只能更新原记录，不能写入之后激活的会话 |
| new / dup | 组内只有组页签与新 pane；来源简要结果可有“定位会话 #N”，用户显式点击才改变聚焦，不因连接完成自动跳转 |
| 复制 | 应用徽标、时间、状态图标为呈现元数据；原生实现复制规则需允许纯命令或命令 + 结果，不能混进隐藏控制字节 |

没有把这套文档式呈现当作本轮原生修复已实现。原生落地时需要真实的有界记录模型、滚动锚点与选择 / 搜索 / 导出策略；此原稿用于评审最终视觉与交互。

## 与现有 V3 / zenit 的关系

沿用 `../settings/styles.css` 的三主题变量与 `../components/` 的组件约定。原稿中使用原生 HTML button / input / select / textarea / table 及 flex 布局，没有外部服务、位图界面或新框架。

| HTML 区域 | zenit 原生映射建议 |
| --- | --- |
| 公共壳 / tabs / split panes | 现有 Workspace / TabModel / 组 roster / pane_manager，`ui.box` 行列和现有可点击节点（无 SplitPane widget） |
| 命令草稿与候选 | 现有 Editor / Palette，原生文本输入及 IME；有界 ScrollArea |
| app-command 记录 | command / operation projection → 终端文档呈现节点；scope 与 owner 控制生命周期 |
| 左栏 / SFTP 长列表 | `ui.widgets.VirtualList`，稳定项目 ID / owner / 当前路径 revision |
| 浮卡 / 菜单 / Tooltip | 原有 `ui.widgets.Popover` / `ui.widgets.Menu` / `ui.widgets.Tooltip`，真实锚点与焦点 |
| 认证 / 文件传输 / 冲突确认 | `ui.widgets.Modal` / 原有 challenge、transfer 控制器；权限与文件选择仍由原生服务负责 |
| 全局提示 | 现有 NotificationHost / Presenter，不能在 terminal pane 另造一套全局提示 |

实际项目为 Zig 0.17.0 和仓库 vendor/zenit；不升级或降级工具链。此交付没有修改原生源码。

## 2026-10-25 完整工作区补全

本轮参考原生 `src/ui/ai_assistant_styles.zig`、`src/ai/float_model.zig`、终端/组/状态/传输控制器及已读取的 Figma **416:1912203**。AI 保留顶部居中 **100×14 三点边条 → 600×456 浮窗**，不是挤压终端的右侧栏。采用 V3 深/浅/Sauber tokens、14px 外圆角；头部 owner 只读，仅收起/最大化/关闭三窗控各22px；历史/新建放消息区轻工具行，输入区90px。浮窗可拖移与右下缩放，始终夹取到内容区；关闭停止生成、收起保留生成，草稿和对话按会话/组 owner 保存。

评审尺寸增加 **1440×900 / 860×480**，URL `size=compact` 可直达最小窗口；不按浏览器宽度缩字。所有 portal 均位于 `#app`，坐标由 APP 边界换算，弹层内部溢出滚动；打开浮卡/菜单/模态会关闭 tooltip。

### 功能、入口、状态与结果

| 功能区 | 产品入口 | 可操作状态与结果 |
| --- | --- | --- |
| 侧栏 | 顶栏唯一折叠钮、⌘B | 224px 展开 / 48px 折叠；折叠钮仍可展开，主机图标可连接，搜索与资产组列表保留 |
| 会话页签 | 标题栏、右键、双击、拖拽 | 页签顺序、重命名、颜色、关闭其他、独立新窗口；⌘1–9、⌘[ / ⌘]、Ctrl+Tab MRU |
| 组 pane | 成员菜单、拖拽、@pin | 左右/上下分栏，成员排序，每组最多一个置顶；移出保活独立于断开关闭 |
| 组关闭 | 组页签 X | 成员影响确认、逐成员关闭进度、停止后续、全部成功/部分失败/unknown；已关闭不撤销，未关闭者保留 |
| 内置指令 | 命令输入 @ 候选、直接输入 | 采纳后可继续编辑参数，来源命令记录 pending→success/error；@new/@dup 只新增一个组成员，不跳源焦点；@ai 问题保留到当前 owner 草稿 |
| 普通候选 | 输入历史前缀、`cd /` / `ls /` / `@dl /`、`@grp ` | 历史/显式路径缓存/组名参数候选，采纳不执行；Esc 保留草稿；Shift+Enter 换行，多行 Enter 逐行确认 |
| 终端搜索 | 终端中键菜单 / ⌘F | 实际高亮匹配行、前后匹配、计数；不会只显示通知假装定位 |
| 历史归档 | 终端中键菜单→历史归档 | 完整/有缺口/空/索引失败与重试；打开独立只读历史页签，原实时会话和组继续；冻结 sourcePrompt，不使用“回放”页签名改写记录 |
| 回放与导出 | 独立历史页工具栏 | 播放/暂停、1/2/4倍速、seek、返回原实时 owner；无输入、广播、转发；txt/cast/png 格式、预览、导出成功/失败模拟 |
| 底栏广播 | 始终可见“广播”区 | 非组说明与建组入口；组内来源选择、接收目标、零接收禁开、批准集合冻结；新增成员未批准、断线跳过、多行粘贴确认 |
| 连接链路 | 底栏“连接链路” | 本地PTY链路；SSH直连/有序多跳示例、逐跳身份/认证/密钥/耗时详情、全链测试报告、共享连接编辑器 |
| 端口转发 | 底栏“端口转发” | 本地不适用说明；SSH L/R规则新增、端口校验、启动/停止/删除；SOCKS5配置与开启，局域网监听二次确认；规则归属当前会话 |
| 文件传输 | 底栏“文件传输”→全局管理 | 当前摘要、空态；queued→running→verifying→done，暂停/继续/取消/失败/校验失败/重试；捕获任务owner和两侧目录，定位不硬跳别的SFTP；关闭会话先暂停保留，任务可从全局继续 |
| SFTP目录 | 两侧目录/文件工具 | 独立path/cache/selection、导航、三个字段排序、预览、loading/empty/error/stale恢复；错误/缓存态阻止传输与写入；SFTP无选中不暗填默认文件 |
| SFTP写能力 | 文件工具→规划写入演示 | 当前原生远端rename/delete能力未开放，默认显示门控说明；开启规划演示后提供真实可点表单/名称校验/删除确认/模拟结果，不冒充已落地能力 |
| 冲突处理 | 上传/下载确认勾选同名冲突 | 跳过、另存为、双方保留、覆盖二次确认；保留多文件名称 |
| 本地异常 | 外部评审状态控制 | 活动进程、Shell退出、PTY启动失败；活动进程关闭确认，退出后重启入口 |
| 连接弹窗 | 顶栏快捷 / 侧栏新建 | 复用 `../connection/index.html?embed=1` 完整三步向导，origin + 文档宿主 source 校验 postMessage；保存只入资产列表，保存并连接只创建一个独立会话 |
| AI未配置/错误 | 场景 `ai-unconfigured` / `ai-error` | 未配置→设置AI服务；请求失败保留草稿、重试；不可用模型/预算超限/附件处理中禁发 |
| AI模型与权限 | 输入区权限 / 模型 / 用量 | 确认后执行 / 完全控制；组写调用仍审批；336px模型浮卡、合法低/中/高滑块；200k/1M模型窗口；历史、引用、终端、身份工具、预留输出的预算分解，可清理恢复 |
| AI上下文 | ＋附件 / `/` | 本地text/image、终端选区、远端文件；远端来源/路径/上级/过滤/列表/读取预览/附加；empty/error/disconnected恢复；处理中→ready、预览/移除/error模拟 |
| AI工具计划 | 提问→模拟回答 | 只读目标与参数、批准/拒绝/准备到输入区；stdout/stderr/exit、失败、unknown不自动重试及查询目标状态；结果不写入PTY |
| 笔记闭环 | 终端菜单/AI结果 | 存为笔记片段/复盘笔记→notes；noteCommand保留多行到textarea且不执行；noteContext→当前AI只读笔记附件；提问草稿保持空，不自动发送 |

### 新场景入口

- [AI浮窗](index.html?mode=ai)、[未配置](index.html?mode=ai-unconfigured)、[请求失败](index.html?mode=ai-error)
- [独立历史页](index.html?mode=history)、[最小窗口](index.html?mode=ssh&size=compact)
- 跨模块参数：`noteCommand`、`noteContext`、`ai=1`；`hostName`只改变示例连接名称，实际地址与身份仍以表单/fixture为准。

### 原生落地映射（以仓库实际导出为准）

已核对 `vendor/zenit/src/ui/components/mod.zig`。按钮/输入/选择器分别复用 `ui.widgets.Button` / `Input` / `Textarea` / `Select`；合法档使用 `Slider`；列表 `VirtualList` / `ScrollArea`；浮卡 `Popover`，菜单 **`Menu`**（不写不存在的 DropdownMenu），提示 `Tooltip`，确认 `Modal`，折叠区 `Accordion`、标签 `Tag`、步骤 `Steps`。TerminalSurface、Editor/Palette、FloatModel、Workspace/TabModel、组roster、challenge/transfer/AI工具控制器均是**项目专用业务模型**，不伪装成 zenit widget。原生必须沿用 owner/session generation、取消确认、资源清理与主线程生命周期；HTML事件不能直接替代这些契约。

## 2026-10-25 V3逐项审计更新

当前壳体统一5pt外边距、36pt顶栏、8pt卡片间隙、26pt底栏、30pt页签；侧栏宽度由实际模型与手动偏好决定；终端JetBrains Mono14/22。新增共享12主题及本地字体资源由 `../theme-tokens.css` 最后载入。任务管理器为锚定Popover，底栏UTF-8/网格/延迟只读，故障演示控制位于APP外评审面板。真实点击发现并修复MRU、页签双击、精确参数Enter、SFTP误入终端组、文件单位排序/mixed、批量冲突范围、任务计时器焦点、SOCKS配置、AI异步owner、共享连接身份链路串用等问题。逐项操作路径、测量及未验分支以为准；不把源码可达等同交互通过。原生内置命令持久记录需要新的终端文档层，不复用AI工具字节格式化器冒充该能力。


## 2026-10-25 细粒度组件与交互对齐

当前版本以[功能组件契约](COMPONENTS.md)为准，`?component=id`加载同一模型与控制器；没有复制第二套组件。页签使用`../shared/functional.js`的`V3.tab`与公共功能外壳样式。主机右键、页签右键和终端中键菜单分开；终端右键粘贴到原输入区，不执行，剪贴板不可访问时明确提示⌘V。单终端不再添加内容顶部工具横幅，搜索、历史、导出等由中键菜单及快捷键进入，分栏成员保留必要pane头部。折叠侧栏主机浮卡包含类型、状态、会话数与地址；页签浮卡包含身份、状态和目录/跳板。命令块与普通文档同起点，移除时间戳样式遗留的50px缩进。底栏延迟并入连接状态。链路浮卡在render重建后按语义锚点重新查找元素，不再定位已销毁节点。

AI继续复用`docs/SPEC/prototypes/v2/index-dark.html`与`vanta.css`的三点入口、600×456浮窗、14px握柄、三窗控、只读owner、75%用户气泡和输入控制顺序，不另起侧栏设计。


## 本轮修正契约（2026-10-25）

- 团队分组只渲染一个SVG折叠箭头，aria-expanded及持久折叠状态同步；侧栏整体折叠由顶栏唯一按钮负责。
- 页签提示和菜单使用独立overlay舞台，不能参与tab宽度计算。独立页签组件仅演示页签管理；新建连接等跨组件动作只提示前往完整模块。
- 时间戳沿用原生terminal_surface按接收/提交行绘制gutter的规则：普通文本、每一行Shell输出、内置指令命令与结果都有时间戳；关闭后统一隐藏。最小分栏prompt换行，输入区保留最小宽度。
- 内置命令来自用户输入时写入终端记录；菜单调用同一操作但不伪造@命令，不清空已有草稿。
- 广播仅配置参与会话及一个总开关。两个及以上在线成员可启用，任一参与终端的Shell输入同步到其他参与成员；内置命令不广播，离线与新增成员不自动加入。
- 信息类hover/focus显示就近摘要；带修改、启动、执行的操作保持点击打开。所有浮卡受APP边界约束，内容可滚动，头尾保持可达。
- 转发提供本地L、远端R及SOCKS5三种选择块。原生当前每SSH会话一个活动listener，HTML同样阻止同时启动第二条。L本机监听→SSH端目标；R在SSH端监听→本机可达IP/localhost目标；SOCKS5动态指定目标。回环默认、非回环确认。停止规则可保留供再次启动，实际活动状态单独计数。
- 助手由shared/ai-assistant.js/css统一提供header/composer/welcome/modelPicker/conversationList，工作区和KVM共用。右上角新建/会话列表及三窗控；新建时保留当前草稿、消息和附件快照，列表可恢复。


## 2026-10-26 二轮评审更新

当前以 、 为准。侧栏为显示/隐藏，不保留图标折叠态；保存主机与会话分离，主机菜单不操作任意一条同主机会话的转发。旧验证截图已清理，相关状态通过 HTML 原型查看。传输使用共享 `transfer-row`，消息使用共享 `feedback`，具体语义、时长和位置见设计指南。


## 2026-10-27 SFTP 确认框与文件菜单

上传、下载确认框采用 480×398 逻辑尺寸，按标题、文件摘要、来源/目标路径、传输选项及操作区组织。路径为本次操作冻结的只读目录；取消不创建任务，开始按钮明确显示上传或下载。超长路径限制在路径容器内，确认框显示期间关闭底层文件提示，避免浮层重叠。

文件右键菜单为 224×154，使用 34px 行高、14px 图标和左对齐文字；重命名仍为禁用状态。菜单沿用点击位置与边界约束。HTML 与原生使用各自真实数据，内容不同不视为布局偏差。

HTML 原型：[SFTP 文件工作区](index.html?mode=sftp)、[小窗口](index.html?mode=sftp&size=compact)。选中文件后打开上传/下载确认，或右键打开文件菜单；历史原生截图已清理，既有尺寸与验收结论保留。

验证覆盖原生真实鼠标拖拽上传/下载及外部文件投放、传输内容校验、860×480 小窗口确认框边界与底层提示关闭；文件工作区相关测试通过。App 产物为 0.2.2，仅构建.app。


2026-10-28：历史回看与AI执行合并为[同一PATCH主方案](../../DESIGN/V0.2.6_AI_SESSION_EXECUTION.md#16-全局历史会话与原会话回看)。两入口共用session-history renderer；阅读位置保存逻辑行/文字锚，resize后重算进度。原生实现状态及局部修复见主方案§17。
