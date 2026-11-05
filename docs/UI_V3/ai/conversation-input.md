# V0.3：跟进行为与 AI 会话操作

本契约复用现有助手、composer、会话列表、关闭确认和设置页；不增加独立助手页面。规则来源为 [0.3 PATCH](../../DESIGN/V0.3_PATCH_AI_CONVERSATION_INPUT.md)。

## 可编辑基准

- [排队卡片](../ai-session-execution/?state=pty-running&followup=queue)：整个队列一张无描边卡片，内部为透明单行消息，序号／状态、正文摘要与图标操作同行；composer 上方正常布局占位。
- [同轮引导](../ai-session-execution/?state=pty-running&followup=steer)、[暂停队列](../ai-session-execution/?state=pty-running&followup=paused)。
- [绑定列表](../ai-session-execution/?state=pty-running&followup=history)、[恢复确认](../ai-session-execution/?state=pty-running&followup=resume)、[使用副本确认](../ai-session-execution/?state=pty-running&followup=copy)。
- [设置 → AI 辅助 → 对话](../settings/?page=ai)、[结束确认](../ai-close-confirmation.html)。

新增状态通过 `shared/ai-conversation-input.js` 和同名 CSS 叠加到既有共享 renderer。没有 `followup` 参数时不插入新状态；确定性原型不执行模型或终端操作。原生以仓库实际的 Zig 0.17 / `vendor/zenit` API 实现。

## 测量与布局

整体结构见[可编辑交互原型](composer-interactions.html)，字号与密度按后续要求继续缩小，队列正文 10px，低于“大浪淘金中”的 11.5px，以下尺寸为当前基准。浏览器 Chrome headless，1440×900 CSS px，100% 缩放、DPR 1，字体加载完成；紧凑工作区逻辑尺寸 860×480。原型助手普通为 600×456、紧凑为 591×342；原生普通助手 600×456，紧凑按原有浮窗约束缩小。比较时使用各自实际助手内容区，不把不同尺寸的整窗拉伸叠图。

| 区域 | 尺寸与约束 | 原生映射 |
| --- | --- | --- |
| composer | 普通状态高 90；原有自适应输入、附件与审批高度规则保持有效 | 原有 Textarea、composer controls |
| 队列 | composer 上方正常列布局，占位；外侧左右 14、底部间距 4；为空时收起 | `ai_pending_view` |
| 单一队列卡片 | 内容器圆角 8，无描边／子卡投影；上下 2、左右 8，头部 18；双条高 58，连同间距占位 62 | 原生 box + `layer_materials.card(.control)` |
| 消息行 | 单行高 18、行间距 0，透明无边框；折叠仅保留 22 高卡片头部，含底部间距占位 26 | 原生 box + Button |
| 消息正文 | 正文 10 / 14，辅助信息 9 / 12，使用次级文字色，单行省略；编辑展开为 48 高 Textarea＋4 间距＋18 操作行，共 70 | Text、Textarea |
| 状态与操作 | 11 图标、18×18 操作槽、6 圆角；默认仅常驻直箭头 ↑／更多，hover 或聚焦显示编辑／移除。槽位保留，正文和高度不跳动；Tooltip 与 a11y 标签说明操作 | Button、Tooltip、Menu 与主题 tokens |
| 队列滚动区 | 右侧固定预留 16px，隔开滚动条及其命中区域与消息操作；普通最多 54（三条）、紧凑最多 36（两条）；编辑时 70，保证输入与保存／取消同时可达。普通总占位最多 80，紧凑 62，编辑 96 | ScrollArea |
| transcript | 高度扣除 grip、header、原有间隔、队列和实际 composer 高度；内部滚动 | 原有 conversation viewport |
| 发送／停止 | 独立的两个 28×28 槽位，间隔 6，区域稳定 | 原有 Button + Tooltip |
| 会话列表 | 宽 440，最高 240，有界滚动；每批 50 条 metadata | 原有 Popover、ScrollArea |
| 历史查看 | 只读 Modal，宽度不超过窗口减 32；正文按窗口及实际换行 footer 剩余空间收缩，底部动作不随正文滚动 | 原有 Modal、ScrollArea、Button |

队列不使用 absolute、fixed 或 portal；列表和历史弹层仍沿用原有 Popover / Modal。必须验证 transcript 底边 ≤ 队列顶边、队列底边 ≤ composer 顶边、composer 操作区在助手底边以内。长队列在卡片内部滚动可以局部裁切，不得覆盖步骤或消息。

## 默认、hover 与键盘

- 整体卡片只增加一次材质层级；消息行、标题、工具栏均为透明布局，文字和图标保持自身语义颜色。HTML 的共享材质分类仅为该队列表面选择 `state-control-base`，与原生 `popupInset` 一致。
- 普通态的 ↑ 表示立即处理该条消息，运行中补入当前任务；当前 SVG 运行态提示为“立即引导当前任务”。不是回复／返回箭头。
- 消息行 hover、任一行内按钮获得焦点、该行更多菜单打开时显示编辑／移除；默认透明并退出鼠标命中，仍可通过 Tab 到达并显现。
- 队列超出可见行数时，Tab／Shift+Tab 自动将当前焦点操作滚入列表；只改变内部滚动位置，卡片与 composer 的尺寸、位置保持稳定。进入编辑时将焦点交给 Textarea；编辑末行时完整显示编辑框和保存／取消操作。
- 图标 hover 与键盘聚焦使用中性 `popupAction` 底色和前景反馈，焦点不画 ring，不替换成默认紫色底。Popover 型 Tooltip 同时支持键盘可见焦点。
- 更多菜单打开时隐藏其触发按钮的 Tooltip，避免提示盖住菜单项；复用原生 Menu 的方向键／Enter／Esc，携原消息票据执行编辑、移除、上移／下移；旧版本菜单在记录变化时关闭并撤销旧按压。折叠仅改变显示，不能暂停或派发任务，键盘焦点保留在展开按钮上；编辑期间禁用折叠。

## 行为与身份

- 设置是应用级 `follow_up_mode`，默认引导；改变只影响新提交。⌘ / Ctrl + Shift + Enter 对本条使用另一种行为，IME 组合中不触发，原 ⌘Enter 换行保留。
- 引导按原 submission 投影为用户消息，明确区分待处理、暂停、待核对和 consumed；不重建 Task、不取消正在返回的模型流来冒充引导。
- 队列编辑、移除、调整顺序、立即引导固定 submission / message revision / queue revision / binding。保存失败保留编辑；排队项被取走、切换会话或结束时，未保存的编辑文字先合入原会话草稿并提示，不自动发送。旧按压不能操作替换后的行。未知交付只提供查看，不自动重发。环境变化后可明确复制文字到新草稿，不沿用旧附件或工具授权。
- 列表点击是查看；已绑定项提供定位、复制，无恢复。未绑定项提供恢复／首次使用。删除要求已解绑且没有未核对交付。
- 恢复到当前 Agent 保留原 ConversationId；复制产生新 ID，只 pin 已完成截点，来源继续执行、后续输出或删除不改变副本。
- 消息回合的分叉入口与列表复制并使用共用同一确认事务；先 pin 所选稳定回合，取消不结束来源。
- 从只读历史点击结束时先关闭历史弹层，再显示原有关闭确认，避免确认被遮挡。确认按钮按文案自然宽度布局，切换主题不恢复过期固定高度。
- 目标已有会话时先明确确认结束影响。结束尚未完成时仍显示已绑定；取消后续恢复／使用副本不撤销已经受理的 End。保存失败保留原绑定并允许同一 operation 重试。
- 只读历史没有发送入口。恢复／复制不请求模型、不自动重连、不执行旧队列；原草稿只在恢复时回到输入框，副本不携带草稿。

## 验证入口

- `zig build test -Dtest-filter='conversation UI'`：真实生命周期服务上的操作事务、来源竞争、固定快照、取消后续步骤和设置值边界。
- `zig build test-ui -Dui-test-filter='conversation UI'`：三主题、普通／紧凑布局占位、旧按压、编辑草稿与只读历史动作。
- [长消息与长队列原型](../ai-session-execution/?state=pty-running&followup=long-queue)：超长中文与组合字符、连续网址、CRLF／Tab、32 个附件计数；检查单行省略、正反 Tab、末行编辑和紧凑窗口。
- `e2e/ai_conversation_input_native.ts`：隔离数据目录、本地终端与确定性回环模型，操作真实主程序；检查队列、同轮引导、复制／定位／恢复／解绑和设置保存。截图用于检查真实像素与布局边界，不能仅凭构建通过判断 UI 完成。

真实外部模型、远端 SSH、真实输入法和 VoiceOver 不由本地确定性验证替代。§19 的全部交叉矩阵也不因这些针对性场景通过而自动视为全量实机验收。
