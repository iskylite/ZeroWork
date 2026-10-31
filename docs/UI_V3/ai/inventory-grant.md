# 查看其他会话：按需授权合同

可编辑基准：[inventory-grant.html](inventory-grant.html)。原生组件为 `src/ui/ai_inventory_grant_view.zig`，使用项目实际依赖 `vendor/zenit` 的 Zig 0.17 公共 API，由原生 Button、文字、图标与 flex 容器组成。复用现有 host approval 外观、V3 主操作渐变与主题 tokens，不改全局组件。

组件默认隐藏，不显示“上下文与来源”、无授权状态、等待发送或提前授权卡。只有 AI 实际请求查看当前绑定范围以外的会话或会话组，宿主发布待决 Snapshot 后才出现审批卡。标题为“查看其他会话”，下面显示本次请求范围和读取说明：

> AI需要查看已打开会话和会话组的名称、连接状态与分组。不会读取终端内容或执行命令。

三个选择始终可见：“拒绝 / 仅此一次 / 持续允许”。一次允许绑定本次调用；持续允许只属于当前对话。决定发出后按钮立即锁定，宿主在安全更新点隐藏卡片。拒绝仅结束本次读取审批，不停止 AI 回合或正在运行的命令。组件自身不能签发权限；回调必须由宿主用捕获的完整 Ticket 验证。

持续授权的撤销入口位于现有“执行权限”菜单，文案为“撤销会话列表授权”。仅 `inventory_authorized=true` 且存在精确 `inventory_conversation_id` 时出现；没有常驻授权信息卡。AI 运行期间仍可打开该菜单并撤销，此时确认/自动执行等原配置项继续禁用，模型和运行方式门禁保持原规则。菜单打开时捕获原对话 ID，撤销 Action 回传原 ID；同一绑定切换到另一对话后，旧菜单不能改用新 ID 发出撤销。

## 测量

浏览器：本地 in-app browser，100% zoom，CSS 视口 600×420、320×420，DPR 1，`document.fonts.status=loaded`。字体为项目 Inter，中文由系统字库补齐。原生截图分别为 1200×840、640×840，2× backing scale。HTML 与原生使用相同内容、三主题和逻辑尺寸；比较目标为审批卡，外部原型评审按钮与原生夹具控制不属于产品。

| 区域 | 600px 视口 | 320px 视口 | 约束 |
| --- | --- | --- | --- |
| 审批卡 | x14/y49，572×153 | x14/y49，292×187 | padding 11，column gap 8，radius 9，border 0 |
| 标题行 | 550×22.5 | 270×22.5 | gap 6，16×16 图标和标题垂直居中 |
| 标题 | 78×20 | 78×20 | 13/20，700 |
| 范围 | 550×16 | 270×16 | 11/16，fg-2 |
| 说明 | 550×18 | 270×36 | 12/18，fg-2，自然换行 |
| 授权范围提示 | 550×16 | 270×32 | 11/16，fg-2，自然换行 |
| 三个动作 | 76×26.5，各间隔 6 | 同左 | 同排、右对齐，最窄宽无裁切或重叠 |

在 600px 视口中三个按钮的 x 为 335、417、499；320px 中为 55、137、219。原生 Button 的 frame 不转发独立 `min_width`，因此本组件为三项短选择显式采用 76px 宽；原生 flex wrap 的行布局也不用于该三按钮行。目标最窄宽 320px 时内宽仍为 270px，足以容纳 240px 动作区。较长说明通过正文换行增加卡片高度。

三主题验证分别为 dark/T=0、light/T=75、sauber/T=100。夹具根部只绘一次主题基色；父表面使用 L1 材质，背景 alpha 分别为 245/255、222/255、214/255；审批卡沿用 `popupAction` 可读底色。文字与图标 opacity 均为 1；透明度只作用于背景。主操作复用既有渐变、轻影和顶端高光。禁用保留 Button 事件门禁与短反馈，不降低整棵控件树透明度。图标与标题同行。

## 交互与验证

| 状态 / 控件 | 原生 test ID | 结果 |
| --- | --- | --- |
| 无待决请求 | `ai.inventory_grant` | display none，无占位 |
| 拒绝 | `ai.inventory_grant.deny` | 仅拒绝本次读取，AI 不停止 |
| 仅此一次 | `ai.inventory_grant.allow_once` | 完整 Ticket + `allow_once` |
| 持续允许 | `ai.inventory_grant.allow_conversation` | 完整 Ticket + `allow_conversation` |
| 不可用 / 失效 | `ai.inventory_grant.feedback` | 短反馈；失效回调禁用再次选择，新请求换票后恢复 |
| 撤销 | `ai.permission.revoke_inventory` | 仅当前对话持续授权存在时出现，回传菜单打开时捕获的 ConversationId |

组件 Snapshot 为 `{ pending: ?inventory_approval.Snapshot, enabled, unavailable_reason }`；callback 为 `on_decision(context, inventory_approval.Ticket, inventory_approval.Decision)`。请求变化会取消旧指针按压。决定在 Button handler 内只发出意图和禁用按钮，不销毁当前分支。

执行的必要验证：

- `zig build test-ui -Dui-test-filter='inventory view' -j2 --summary all`：32/32 通过，含按需隐藏、三种决定、键盘、重复点击、失效反馈、禁用恢复、按压中换票和三主题/最窄宽布局。
- `zig build test-ui -Dui-test-filter='AI composer' -j2 --summary all`：58/58 通过，含仅持续授权出现的撤销、运行中撤销且配置保持禁用、撤销消失/切换绑定的旧选择以及同绑定更换对话 ID 的旧菜单。

实际点击拒绝、一次允许、持续允许、后续请求免重复审批、现有权限菜单运行中撤销、禁用和失效反馈；六个进程均通过正常 `/quit` 退出，退出码 0。

这些是生产组件与 broker 的隔离夹具，使用合成身份、独立 RPC 和数据目录，没有构造 ApplicationHost，也不读取用户工作区。真实应用的 provider/请求接线由主应用场景另行验证；这里不以隔离组件截图宣称真实查询路径已验收。

最后一次禁用渐变修正使用本组件显式实色渐变替换 inline style host 中保留的旧主操作渐变；没有修改全局 Button。修正后定向 UI 仍为 32/32 通过，并只补验三个主题、320×420 原有视口中的 disabled/expired 六张实际 Metal 截图。完整六场景交互报告生成于该单行样式纠正之前；最后修正后的业务行为没有另行扩大回归范围。
