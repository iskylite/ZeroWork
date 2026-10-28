# AI 会话执行 · 可编辑 V3 效果稿

本目录是 V0.2.6 AI 会话执行的设计基准。所有主机、命令、终端输出、审批与关闭结果都是确定性模拟，不连接 SSH，不启动 PTY/exec，不调用真实工具，不修改实际文件。它不代表这些能力已由产品实现。

设计约束：直接载入现有 `workspace` 的结构、样式和 renderer，保留原会话组、会话卡片、成员操作、终端及原输入位置。受控卡片仅在右下角增加“AI 控制 • 只读”tag 和“接管”按钮；tag 直接使用现有 `badge accent`，接管直接使用现有 `button secondary`；该组统一28px高、11px字号、20px行高并居中；颜色、圆角、描边、阴影与交互态沿用现有组件。颜色复用主题的 `sel/accent/hover/fg`，不新增独立色值；控制期间该卡片只读。不增加底部输入栏、发送按钮、顶部 AI 控制栏或 AI 专用终端。助手中的模式、审批和工具卡保持本 PATCH 已确认设计。

## 运行与场景

从仓库根目录启动静态服务，例如 `python3 -m http.server 8768 --bind 127.0.0.1 --directory .`，访问 `http://127.0.0.1:8768/docs/UI_V3/ai-session-execution/`。不需要安装依赖。下面的 URL 相对于本模块目录。

| 场景 | URL | 验收内容 |
| --- | --- | --- |
| 全局设置 | [settings](./?state=settings&theme=dark) | 默认自行判断、五种运行方式、默认空闲后关闭（auto_idle）与保存 |
| 对话运行方式 | [mode-menu](./?state=mode-menu&theme=dark) | 继承全局、当前对话覆盖、次级任务结束策略 |
| 批处理结果 | [exec](./?state=exec&theme=dark) | 保留完整 identity、cwd、command、stdout、stderr、exit、elapsed 与结果 |
| 每次询问与审批 | [ask](./?state=ask&theme=dark) | 路径选择、具体命令、目标与影响，在一个审批卡中确认 |
| 新 PTY 运行中 | [pty-running](./?state=pty-running&theme=dark) | 来源与工作会话双 pane，真实三工具步骤，AI 持有目标输入权 |
| 已有组内新增 | [pty-running / existing group](./?state=pty-running&group=existing&theme=dark) | 只显示 open_session、run_in_terminal，不再创建组 |
| 已有 PTY | [pty-running / existing target](./?state=pty-running&target=existing&theme=dark) | 当前原有 session-07 单 pane 获得 AI 输入权；不建组、不新建会话，只显示 run_in_terminal |
| 等待输入 | [pty-waiting](./?state=pty-waiting&theme=dark) | 合流终端输出、等待提示、允许输入 y / 接管输入 |
| 用户接管 | [takeover](./?state=takeover&theme=dark) | 撤销 AI 写入，前台程序仍在等待，host_notice 保留 |
| 封存中 | `?state=pty-sealing` | 进程完成后仍等待持久化收据，确认后进入已完成 |
| 停止待确认 | `?state=pty-stopping` | 停止请求与接管分开，核实后可返回结果未知 |
| 停止未知 | `?state=pty-unknown` | AI授权已撤销，前台结果未知，会话不自动关闭 |
| PTY 完成 | [pty-done](./?state=pty-done&theme=dark) | 输出和过程可回查，输入权已交回，可处理任务会话 |
| 关闭后的历史 | [history](./?state=history&theme=dark) | @log 只读历史，保持 cmd-42 关联，查看记录不重连不重放 |
| 任务结束处理 | [cleanup](./?state=cleanup&theme=dark) | 保留 / 关闭任务会话，原会话与组保持打开 |
| 清理待核实 | [cleanup / pending](./?state=cleanup&cleanup=pending&theme=dark) | 未确认关闭结果前不显示已清理，可核实状态 |
| 已清理 | [cleanup / cleaned](./?state=cleanup&cleanup=cleaned&theme=dark) | 工作会话变为 @log，组保留，不自动回到单会话 |
| 保存失败保稿 | [settings-error](./?state=settings-error&theme=dark) | 首次保存失败，保留设置草稿，再次保存成功 |

所有场景共用 `app.js` 的 renderer 与 fixture。`theme=dark|light|sauber` 和 `viewport=default|compact` 可组合；产品画板分别为 1440 × 900 和 860 × 480；最小窗口助手为600 × 358。当前审批占满可用transcript内容区并默认滚动定位，上方消息保留在外层滚动区供回查；实际目标、目录和完整命令初始可见，影响说明可在审批正文内部滚动。菜单正文内部滚动，批准footer、composer及停止按钮保持固定可达。评审栏位于产品画板外。首选入口为 `pty-running`。

## 共享组件与交互映射

| 组件 / 稳定入口 | 可观察结果 |
| --- | --- |
| `review-state`, `review-theme`, `review-viewport` | 更新 query 和当前画板，复用同一组件实现 |
| `open-settings` → `global-mode-*`, `global-end-policy`, `save-settings` | 保存新的全局默认；对话中的独立覆盖不受影响 |
| `permission-trigger` → `permission-confirm` / `permission-auto` | 独立保留原“确认后执行 / 自动执行”权限控件与存储，不与运行方式互相改写 |
| `context-budget` | 保留上下文预算入口，紧凑显示1.3k，提示和点击可查看1.3k / 128k |
| `run-mode-trigger` → `mode-inherit` / `mode-auto` / `mode-ask` / `mode-exec` / `mode-attach` / `mode-new` | 选择当前对话覆盖，或即时恢复继承；回到输入框时显示当前有效方式 |
| `override-end-policy` | 次级菜单中设置当前对话任务结束策略；继承全局为默认 |
| `composer-draft` | 本原型专属草稿保存，刷新读回；Cmd/Ctrl+Enter 发送 |
| `approval-path-*` → `approve-execution` | 在同一审批卡选择批处理 / 已有 PTY / 新 PTY，命令和影响同步变化；确认进入对应状态 |
| `reject-execution` | 拒绝本次调用，返回输入框；不执行命令 |
| `create-group-step`, `open-session-step`, `pty-command-card` | 原生 details，可用鼠标、Enter、Space 展开；步骤明细中的工具名与实体 ID 一致 |
| `exec-command-card` | 使用同一命令卡 renderer，新增“批处理”类型标记；保留完整结果字段 |
| `view-terminal` | 收起助手、定位目标 pane 或 cmd-42 对应 @log，展示当前输入权 / 只读条 |
| `view-process` | 打开可滚动过程面板，按时间显示真实工具调用及 host_notice |
| `ai-control-tag`, `takeover-terminal`, `takeover-card` | 目标卡片右下角显示 AI 控制 • 只读；先撤销 AI 后续写入，再恢复原终端输入并移除 tag/按钮；不注入 Ctrl-C、不改变输出或结束前台程序 |
| `stop-execution` → `verify-stop` | 中断已请求 → 等待执行证据 → 结果未知且AI授权撤销；不伪装用户接管或执行成功 |
| `seal-record` | 模拟取得持久封存收据；取得前不开放任务收尾 |
| `confirm-pty-input` | 模拟本次 y 输入获批，转回运行中；无真实终端写入 |
| `keep-task-session` | session-18 保留，用户来源 session-07 与 group-03 不变 |
| `close-task-session` → `verify-cleanup` | 先进入“清理待核实”，核实后才关闭任务会话；@log 保留，原会话与组仍打开 |
| `copy-command-result`、既有终端复制/选择 | 命令卡分别复制当前真实命令/输出，排除ID、耗时与状态装饰，终端沿用原有复制与选择，不增加 pane 顶部复制按钮 |
| `reset-prototype` | 仅删除 `zerowork.v3.ai-session-execution.v1`，恢复本原型设置与草稿，不清理任何其他 V3 存储 |

运行方式、结束策略、对话覆盖、独立执行权限、输入框草稿和设置草稿共用上述专属 localStorage key。结束策略枚举与生产文档一致：`auto_idle`（默认，空闲后关闭）、`ask`（每次询问）、`keep`（保留）。它只作用于 created_task，借用的原 session-07 不随任务自动关闭。设置失败场景保留未提交的设置草稿；它不改变已保存的默认值。模拟的执行 / 审批 / 接管 / 清理状态由 query fixture 驱动，不持久化成真实产品记录。

键盘支持：助手按钮与 summary 可聚焦；Esc关闭菜单、过程或设置，Alt+R打开运行方式，Cmd/Ctrl+Enter发送。终端沿用原组件的键盘、选择与滚动；控制期间阻止目标卡片输入，接管按钮仍可用键盘操作。

## 复用现有组件

画面和 fixture 使用便于阅读的短名；`create_group` / `open_session` / `run_in_terminal` 等工具短名对应生产设计文档中的 `host.<name>` 逻辑 ID，wire 编码由现有编码机制处理。`host_notice` 是宿主写入 transcript 的事件，不是工具步骤。旧 `run_command` 执行管线不改。原型模式短值 `exec` / `attach` / `new` 分别对应生产 `isolated_exec` / `attached_pty` / `new_pty`；`auto` / `ask` 同名。不要直接把 fixture 短值作为生产配置枚举。

| HTML renderer / 状态 | 后续 zenit 映射 |
| --- | --- |
| 现有 `workspace/index.html`、`styles.css`、`app.js` | 直接复用工作区、组、`terminalPane`、`logMarkup`、终端内原有 `.input-row/.command-input` 和历史页；本目录不再提供平行 shell/pane/input renderer |
| `toolCard`, `commandCard` | 复用既有原生步骤折叠组件；仅新增执行类型字段，批处理结果保留 stdout / stderr 分流 |
| `setupCards` | 工具流依次承载 create_group / open_session / run_in_terminal；已是组时省略 create_group；已有 PTY 仅 run_in_terminal |
| `approvalCard` | 一个确认组件绑定 route + command + target + impact，并提交一次审批意图 |
| `modeMenu`, `settings` | 原生菜单、radio / select、设置保存事务；全局默认与对话 override 分开存储 |
| 卡片右下角 tag / 接管 | 会话卡片唯一新增 UI；目标卡片只读，既有输入组件不替换、不另包一层，其他卡片正常输入 |
| `hostNotice`, `processPanel` | host_notice transcript 项与原工具调用记录共享实体 ID；不要伪造 assistant 工具返回 |
| 现有 `@log` / 历史页 | 按既有历史设计只读打开已关闭 PTY 的记录；不得发起重连或重放，不新增一套历史 pane |
| `cleanupCard` | 独立关闭任务会话请求与已确认结果；未知结果先显示待核实，不标记已清理 |

本目录交付 HTML/CSS/JS 基准。统一PATCH及已有Zig局部修复见[主方案](../../DESIGN/V0.2.6_AI_SESSION_EXECUTION.md)，不能将局部修复视为新AI工具已实现。实际映射到 zenit 时仍需核对项目当时依赖的 API，并对照实际原生窗口验证。

## 本需求的样式与尺寸合同

| 区域 | 合同 |
| --- | --- |
| 主题 | 直接读取 `../theme-tokens.css`；dark / light / sauber 使用相同语义颜色、轻材质与控件结构 |
| 外壳与会话卡片 | 完全复用现有 workspace 参数，不由本 PATCH 覆盖标题栏、侧栏、组布局、pane 标题/工具或终端字号 |
| 助手 | 保留本 PATCH 的600×456正常/600×358紧凑助手；会话卡片与终端尺寸由原 workspace 决定 |
| 输入框 | 固定90 px，textarea46 + 控件行28；左侧附件→权限模式→运行模式，右侧上下文→模型/推理→输入/状态/发送或停止，左右对齐；不增删或改小控件。运行方式放折叠菜单，不把五个选项常驻输入框 |
| 工具卡 | header32，r9；正文与对话分开滚动；footer 保留查看终端 / 记录、查看过程、接管 / 输入动作 |
| 文字 | 助手标题13，产品正文12.5，设置选项12，步骤标题11.5，输出11；小字只用于 ID、时间与辅助元信息 |
| 终端输出与输入 | 直接复用原终端。新建 PTY 是组内普通会话卡片，仅目标只读；附加已有 PTY 仅将该卡片变只读。右下角为 AI 控制 • 只读 + 接管，其他输入位置与交互不变 |
| 批处理 | identity / cwd / command、分离的 stdout / stderr、exit code、elapsed、结果字段完整可展开 |
| PTY | live、附加 PTY 使用现有 `terminalPane/logMarkup`，历史使用现有历史页。不显示 AI 命令装饰，不另造底层输入组件及上层封装组件。命令 ID 留在工具卡和记录元数据；未提供退出码时显示 `exit —` |
| 图标 | `app.js` 中只复用当前工作区 svgPaths 的所需子集；回合状态复用既有 sparkles SVG，避免引入不同角色素材 |
| 反馈 | hover / focus / pane 定位用约150 ms paint反馈；菜单、工具折叠使用原生控件语义；尊重 reduced motion，不加循环装饰动画 |

精确颜色为浏览器解析当前 theme token 的结果。此处记录源约束，不把 CSS 声明假称为实际测量。历史计算样式与交互检查见[专项验证记录](verification/README.md)，效果图统一通过 HTML/CSS/JS 查看，历史截图已清理。

## 当前限制与验证责任

- 静态检查：`node --check app.js` 通过。原型直接使用本地 workspace/shared 资源，无真实 SSH/PTY/exec 请求。旧独立 shell/pane/input fixture 的静态验证不再作为当前稿证据。
- 命令卡、host_notice、审批、接管与清理均为可点击 fixture；不会验证真实 PTY 的前台状态、退出码、SSH 身份或运行结果。
- 关闭会话先展示“待核实”，原型中的“核实状态”是确定性转移，不是实际后端确认。
- 连接、模型、附件等沿用既有 V3 的外围入口只展示上下文反馈，本稿不重做这些既有功能。
- 不将原型挂成新产品模块，不修改共享脚本、现有 workspace/settings 页面或原生实现。
- 用户纠正后，已检查原11主状态和三主题/两尺寸，完成6项针对性的只读、接管与原输入/历史复用浏览器检查；详见专项验证记录。此前另造终端布局的截图与验收口径已被本轮替代。


## 2026-10-28 合并评审修订

AI关闭后的记录与全局列表共用 `ZeroWorkHistory.register/open`、ArchiveKey与同一原会话renderer；cmd-42仅提供区间定位参数，不再创建type=history的旧页面。短记录滑轮禁用并显示唯一真实时间；没有返回实时入口。全局入口再点同一记录聚焦同一Tab。

历史阅读保存 entry/row/text offset 逻辑锚，缩窗重新换行后按锚定位，再计算百分比。停止/结果未知/封存中使用独立fixture状态；这些是可点击原型，不模拟后端已取得真实收据。专项验证结果和截图见[合并评审验证](verification/review-20261028/README.md)，较早截图仅代表当时版本。
