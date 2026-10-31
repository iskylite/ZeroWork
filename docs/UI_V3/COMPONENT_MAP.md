> 冻结边界见[冻结清单](FROZEN.md)：连接和设置保留拆分前已确认的完整模块，本轮仅按用户明确缺陷定点修复。

# V3 逐级拆分、复用与融合合同

本轮以已落地的终端鼠标/菜单语义、V2交互原型的页签与AI浮窗、V3的颜色/尺寸规范为基准。保留原型结构与事件，将通用规则抽到唯一来源，而不是按页面分别重画。

## 四层组织

| 层级 | 入口与职责 | 唯一来源与组合方式 |
| --- | --- | --- |
| 通用组件 | [分类目录](components/index.html)，输入、选择、动作、浮层、工具、反馈、集合、异步和通知 | `components/primitives.css/js`供设置与展板共同消费；复杂选择器由`connection/select-preview.js/css`共享。展示页按功能路由复用同一模板/控制器 |
| 功能组件 | [独立能力目录](features/index.html)，页签、主机导航、终端输入、命令文档、会话菜单、状态、链路、广播、转发、传输、AI、连接向导步骤、设置事务、模型行、KVM控制等 | `features/catalog.js`只登记来源与依赖；画布通过受控component/feature路由挂载模块中的真实renderer/controller，不复制业务界面或另一份任务队列 |
| 功能模块 | [模块入口](index.html#modules)，终端与文件、连接管理、偏好设置、KVM、笔记 | 组合通用及功能组件；模型持有实体、草稿和操作状态，壳可以重绘，业务归属不跟随active切换 |
| 整机预览 | [融合入口](app/index.html)，连接会话切换、管理工具浮层、共享主题、通知、传输聚合 | `app/app.js`负责路由/实例生命周期及全局服务投影；`app/bridge.js`是HTML挂载适配，原生须映射Window/Router/WorkspaceModel等，不使用WebView替代 |

同类组件不止共享颜色。页签的HTML由`shared/functional.js`中的`V3.tab`生成，workspace、connection、KVM、notes共同消费；槽位、状态点、关闭命中、hover/focus与尺寸由`shared/functional.css`定义。AI头部与链路测试阶段分别由同一`V3.aiHeader`及`V3.connectionTest`渲染。其业务动作仍分别发回原Session/Connection/Note控制器。设置基础控件和组件展板也消费同一个primitives源。

## 功能组件合同

| 功能族 | 状态/输入与输出 | 归属/基础依赖 | 原生映射 |
| --- | --- | --- | --- |
| SessionTabStrip | 实体投影、选中、关闭、菜单、完整身份浮卡、溢出/拖序 | stable tab/session/group ID；按钮/Tooltip/Menu | 项目TabStrip组合公开Tabs与生命周期控制器 |
| HostNavigator | 协议/地址/状态/已打开会话数；展开/折叠/搜索/右键 | HostId；列表、Icon、Popover、Menu | 受控主机模型+VirtualList/Popover；未知状态不伪造 |
| TerminalInput/Menu | 草稿、补全、IME；右键粘贴、中键菜单；tab/host有独立菜单 | 原终端owner；输入引擎和上下文菜单 | 现有TerminalSurface/terminal_surface_input/context_menus |
| BuiltinCommandRecord | 命令、输出、pending/success/error；更新原记录，文档行对齐 | command/operation ID；文本/状态 | 应用终端文档层，不能用AI FormattedOutput代替 |
| ConnectionStatus/Path | 状态中含延迟；独立路径、分阶段配置/认证检测、失败恢复 | 会话和attempt快照；Popover/Rows | 同一连接服务/阶段模型；配置有效不等于目标认证成功 |
| Broadcast/Forward | 广播参与成员与总开关；L/R/SOCKS5监听/目标/冲突、开始/停止 | 稳定session IDs；每SSH会话一个活动listener；选择/表单/反馈 | WorkspaceModel/转发服务，不由界面active猜owner |
| Transfer | 目录/选择、冲突、任务/进度/暂停/恢复/来源 | JobId + source/target owner；集合/异步 | 全局服务投影原任务，同一个队列 |
| Assistant | 保留既有顶部边条、600×456浮窗、握柄、窗控、90输入区；历史/工具/许可 | 会话/组owner、message/operation IDs；输入/菜单/浮层 | 现有FloatModel与composer adapter；不改成另一种常驻栏 |
| ConnectionEditor | 创建/编辑、路径、核对、预检、认证及取消 | 草稿与host快照；Input/Select/Modal/Steps | 单一ConnectionEditor组件，各入口通过参数复用 |
| SettingsNavigation/Transaction/ModelRow | 分类与搜索、草稿/校验/保存/放弃、单行模型与能力 | settings revision/provider/model IDs；primitives和原模板 | 设置模型/公开表单及事务控制器 |
| KVM Control/Display/Keys/Power/Boot | 只读/控制/租约、帧坐标、接受/核实/未知结果 | 当前连接代际与批准快照；菜单/输入/反馈 | 原生纹理/输入/协议服务，HTML画面仅夹具 |
| NoteEditor/Actions | 编辑预览、命令准备、AI附件确认 | 原note及目标会话快照；输入/菜单/确认 | Markdown/文件服务；上下文不自动发送 |

每个功能组件页给出通用依赖、唯一实现源、消费模块与交互说明。组件示例仅装载受控fixture；不另建一套业务数据来“演示成功”。分类不机械拆到每一个label；以独立状态合同与可验收用户能力为边界。

## 范围及未来设计

当前整机连接范围为本地、SSH、SFTP和KVM。VNC/RDP/FTP的研究稿保留在[未来设计](future/index.html)，必须显式future=1进入，默认协议选择、侧栏、模块导航及整机路由都不包含它们。KVM按用户明确要求作为已完整规划的模块参与组合。笔记仍为此前已授权的设计模块，不改变其原型模拟身份。

## 布局/命中不变量

- 标准1440×900，最小860×480；独立面板在可用画布居中。固定头脚不压缩，菜单/正文各自`min-height:0`与有界overflow，最后一项能滚到。
- 标题左侧只保留一个侧栏折叠控件；整机模块导航移到右上动作区，侧栏内重复折叠按钮省略。没有对应动作的图标使用默认指针，动作统一pointer，编辑区text，resize/drag保留专用指针。
- 单终端/单KVM内容不增加身份操作横条；split才有pane标题及操作。状态/身份可由tab、hover与底栏查看。
- 浮层锚点以稳定控件身份重取位置，侧栏折叠或状态栏重绘后禁止沿用脱离DOM的rect。Popup布局限于APP内并恢复原触发点焦点。
- 模态内容、遮罩及inert/focus一起建立和释放。关闭、取消、第二次打开都要验证；只剩遮罩视为失败。

## 逐级验收

基础组件状态 → 同一功能组件隔离页 → 功能模块完整流程 → 整机跨模块连线。变更共享源后检查实际消费者，不能只截展板。当前记录见；能力与实现限制见[Zenit核查](ZENIT_READINESS.md)。

## 本轮组件展示边界修正

功能区按本地ZSH、SSH、SFTP、AI、顶栏、侧栏、底栏、连接、设置、KVM及笔记组织；相同业务仍消费同一renderer/controller。功能组件是一条可独立验收的状态/事件合同，例如“端口转发浮卡”，而不是整条底栏或整个工作区的裁片。

- 页签故事只展示页签条及完整页签菜单；其他功能给范围说明或打开来源模块，不在62px高裁片里挂向导。
- 底栏各故事只显示自身触发器及完整浮层；另有完整底栏组合故事，明确不同层级。
- KVM各故事只显示该工具按钮及完整浮层；AI只显示共享助手，无淡化终端/视频背景。
- 组件根舞台保留完整可用高度作为浮层边界，展示部件按内容布局；不能把部件高度同时当浮层最大高度。resize后重取活触发器锚点；长浮层内容滚动且头部可达。
- 只读信息使用hover/focus就近显示；选择、保存、启停等动作仍显式点击。含必须操作的浮卡不能以hover离开即消失。
- 原型固定860×480最小逻辑尺寸，菜单/弹层可达；通用/功能组件前后导航保留主题与尺寸。关系文档使用Markdown阅读器，不裸露堆叠语法。
- 整机中央仅承载终端、文件、KVM等连接内容；连接管理、设置、笔记工具以面板/浮窗挂载，关闭返回原连接草稿。
