# ZeroWork 原生窗口验证

AI 答复恢复专项：`zig build ai-recovery-preview -Dtest-mode=true -j2` 后运行 `node e2e/ai_answer_recovery_native.ts /tmp/zerowork-answer-recovery`。隔离窗口复用生产恢复卡片，以合成快照检查未知结果、冷却、上下文失败的可见说明、按钮禁用、详情及 600/360 逻辑宽度。命令不重放、未知回执保留、异常工具调用拒绝和归属／预算检查由 `zig build test -Dtest-filter='answer retry' -j2` 验证；卡片预览不代表真实 SSH 已核查。

原调用只读核查：同一 `ai-recovery-preview` 构建后运行 `node e2e/ai_readonly_verification_native.ts /tmp/zw-readonly-verification`，检查原目标、追加证据、旧记录缺少定位信息、原连接失效及 600/360 布局，核查后新计划仍禁用。`zig build test -Dtest-filter='readonly verification' -j2` 和 `zig build test-ui -Dui-test-filter='readonly verification' -j2` 覆盖调用/参数与generation绑定、原SSH快照、零取消/关闭/重放、终端观察不回退到有副作用的snapshot、证据复制及journal重启。预览与受控回执不代替真实服务器业务后果核验。


使用仓库实际依赖的 Zenit Harness 和本机 Node 26，无需安装服务或 npm 依赖。

KVM 窄分屏工具栏：`zig build bmc-kvm-preview -Dtest-mode=true -j2 --prefix /tmp/zw-kvm-toolbar-build` 后运行 `node e2e/kvm_toolbar_native.ts /tmp/zw-kvm-toolbar-build/bin/bmc-kvm-preview /tmp/zw-kvm-toolbar-evidence`。独立窗口复用生产 renderer，在宽窗口内分别分配 520、336、280、240 点会话宽度，检查图文→五项纯图标→三点收纳、连接状态图标及提示、所有直接入口、菜单边界、键盘进入与回焦、外部点击和拉宽恢复；覆盖晴霜与深色主题并保存原生截图。使用本地合成视频与类型化服务，不连接真实 BMC、不执行电源或启动写入。布局与输入回归使用 `zig build test -Dtest-filter='BMC view' -j2`。

```sh
zig build -Dtest-mode=true -De2e-port=19818 -j2
node e2e/workspace.ts --out /absolute/path/to/evidence
```

文字操作按钮与主题专项：`./scripts/test_isolated.sh test-ui -Dui-test-filter='button policy' -j2` 遍历当前全部内置主题，检查保留节点的次按钮底色／文字、悬停／按下／无描边焦点、禁用门禁及复制反馈恢复颜色。`zig build button-policy-preview -Dtest-mode=true -j2 --prefix /tmp/zw-button-policy` 后运行 `node e2e/button_policy_native.ts /tmp/zw-button-policy /tmp/zw-button-policy-evidence`，在独立原生窗口复用生产远程提示条、AI 恢复卡片、复制反馈和执行／传输／通知的真实样式；遍历主题，并保存代表主题的常规／最小窗口和交互状态。回执为合成数据，不访问钥匙串、真实服务器或模型，不作为主程序启动或真实会话操作的端到端证据。

本地终端原页签重连：`node e2e/local_reconnect_native.ts /absolute/build-prefix /tmp/zerowork-local-reconnect-evidence`。使用隔离数据和真实 zsh PTY，验证 Ctrl+D／非零退出后的“重新连接”、原页签复用、自动回焦、连续重连、860×480 布局及关闭后的进程释放；保存原生截图和报告，最后正常退出应用。

普通 `zig build` 的 `test-mode` 默认为 `false`，发行构建保留该默认值。
`e2e-port` 仅定义默认文件 RPC 目录后缀。Runner 每次创建独立 RPC、应用数据目录和进程，使用它刚启动的 PID，不复用正在运行的用户窗口。

默认步骤捕获 1440×900、860×480 两种逻辑尺寸，并请求 640×360 后断言实际根节点仍为 860×480。每次 resize 等待真实渲染帧递增再读取布局。应用必须已设置 `WindowConfig.min_width/min_height`，该断言才会通过。

输出目录包含 PNG、对应节点树、`app.log` 和 `harness-report.json`；报告记录可执行文件 SHA-256、实际根尺寸、渲染统计及逐步结果。Runner 的通过只表示所列步骤通过。

可以通过 `--binary /absolute/binary` 指定刚构建的验证程序，通过 `--steps /absolute/steps.json` 提供步骤数组：

```json
[
  { "action": "resize", "width": 1440, "height": 900 },
  { "action": "visible", "test_id": "workspace.shell" },
  { "action": "size", "width": 1440, "height": 900 },
  { "action": "capture", "name": "workspace" }
]
```

交互步骤支持 `click`（`test_id`）、`key`（`name`、可选 `mods` 中的 `cmd/ctrl/alt/shift`）、`type`（`text`），以及 `text`（`test_id`、预期 `text`）断言。控件 ID 以实际节点树为准。截图名称仅含字母、数字、下划线和连字符。

截图来自真实 Metal 呈现表面，不包含 AppKit 原生交通灯；交通灯位置及原生点击行为需补充系统窗口截图和操作验证。合成键盘输入也不能代替真实输入法验收。后台运行不会抢前台，收尾仅终止 Runner 自己启动的进程；这不作为应用正常退出与资源关闭链已通过的证据。

`--fixture-dir /absolute/path` 会将指定本地目录复制进本次隔离数据目录，可提供 `config.toml` 和 `hosts.toml`，不会修改原始 fixture 或用户默认数据。报告不复制 fixture 内容。

App历史自动提示专项：构建最新test-mode二进制后，运行 `node e2e/completion_nested_ssh_native.ts /tmp/zerowork-completion-new-run /absolute/path/to/zerowork`。Runner在隔离本地zsh中定义`ede`别名，经系统SSH连接自建loopback服务及真实zsh PTY，验证`find`自动显示先前命令、→仅发送缺少后缀、Enter与Tab原样提交、Esc抑制、登录密码排除及860×480浮层。仅操作自建进程、配置和目录；截图需查看，不代表物理键盘或IME已验收。

`visible` 会等待节点实际获得可见尺寸；`hidden` 会等待节点消失或不可见，可用于确认页签真实移除。`capture` 等待 300ms 让控件进出动画结束后保存视觉证据；它不替代功能完成断言。

`rect` 可按test_id核对实际全局坐标（x/y/width/height，容差0.5px）。`visible/hidden`检查整条祖先可见链，避免隐藏容器内旧节点误判。

`drag` 支持test_id、to_test_id、edge(before/after)及cancel，cancel会在鼠标松开前发送Esc；`tab_order`通过实际可见坐标核对TabId顺序。`block_config_save`仅操作本次Runner自建data目录，将原config.toml改名保留后创建同名目录，用于触发真实写盘失败，不修改产品保存逻辑或用户默认数据。

页签快捷键专项使用 `node e2e/tab_shortcuts.ts --out /absolute/evidence --fixture-dir /absolute/local-refused-fixture`。Fixture 提供一项已保存的本地拒连连接和短连接超时；Runner 创建十个真实会话页签，核对前九项 Command 序号及逐项切换、无 Command 修饰的下一事件恢复图标、860px 下 overflow 首尾几何与禁用门禁，以及连续 Ctrl+Tab 的完整 MRU 顺序和 Shift 反向。查询只读取页签子树，避免完整终端树超过 Harness 结果上限。

该专项仅用公开 Harness API，后台启动独立 PID/data/RPC。当前 Harness 没有 `key_up`，因此 Command/Control 实际松开、窗口失焦与真实 IME 仍需另外通过 CUA 验证；无修饰的 `key_down` 不能作为实际松开凭据。

`scroll` 通过目标节点中心发送真实Harness滚轮事件（`test_id`、`dy`）；`focused` 核对当前实际焦点的 `test_id`，用于阅读位置与浮层回焦验收。按键名沿Harness公开接口使用小写（例如 `backspace`、`return`），不能把未知名称返回ok当成按键已生效。

`hover` 按 `test_id` 通过公开Harness鼠标移动并等待tooltip延迟，可验证不可用原因和完整标题；不能把它当成原生系统鼠标/输入法验收。

## 按钮与尺寸约束审计

`python3 scripts/audit_ui_constraints.py --out /tmp/ui-constraints.json` 生成生产源码逐点清单，保留固定/参数化/内容/可用空间/上下界表达式，不把固定尺寸自动判错。

`node e2e/button_constraints_native.ts /tmp/ui-button-evidence` 使用当前test-mode二进制，在1440×900及860×480检查首页、快速连接、八类设置展开与滚动、Local/AI及重命名取消。加位置参数 `path` 单独复验长中英文下载目录：省略label、完整有界Tooltip和Esc。行为断言、几何候选与像素验收分别记录；runner不调用外部服务或真实删除操作。

传输浅卡片与关闭专项使用 `zig build transfer-controls-preview -Dtest-mode=true -Dtransfer-preview-presentation=global_popover`（另可选`session_popover`、`session_tray`），然后 `node e2e/transfer_controls_native.ts /absolute/bin/transfer-controls-preview /tmp/transfer-controls-new-run fixture`；tray模式用末参数`tray`，正式应用关闭检查用正式test-mode二进制及末参数`main`。该fixture复用生产renderer和按钮，仅使用合成任务。必须检查76px卡片（84px排列节距、3px进度）主行及元信息完整可见、默认不显示复选框、管理后选择、按钮直接展开、450ms hover分组详情及完成上传复制路径、SFTP按owner及上传/下载方向分列、无任务隐藏且不占位、卡片之间无细线分割、X后面板隐藏及重新打开后的第二次关闭，不能只验发送click成功。

传输入口与全局进度环专项：先执行 `zig build -Dtest-mode=true -j2`，再运行 `ZW_TEST_PYTHON=/absolute/python-with-paramiko node e2e/transfer_entrypoints_native.ts /absolute/bin/zerowork /absolute/fresh-output --live-transfers`。脚本始终使用自建 loopback SFTP 和真实上传；`--live-transfers` 保留兼容，`--foreground` 检查前台原生激活。验证已知大小时的百分比、含未知大小排队任务时的不定进度环、控件边界、悬停不弹窗、工具栏／Esc／关闭按钮、860×480 列表边界、接收端 SHA-256、完成后恢复空闲图标及正常 Quit。当前入口不显示数字角标，不再以旧底栏轮播作为验收条件。Runner 设置 `ZENIT_E2E_REAL_ACTIVATION=1`，截图需实际查看。SFTP 栈溢出定向回归为 `zig build test-ui -Dui-test-filter='SFTP progress' -j2`，包括 2 MB 栈上的连续刷新与快照独立性检查。

通用结构回归：`zig build test-ui -Dui-test-filter='UI constraints' -j2`。

## 私有实机输入与证据

仓库不保留实际服务器配置、主机指纹、Provider 私有端点或密钥；一次性用户网络验收脚本已清理。保留的 loopback/fixture 及本地回归只使用受控资源。远端 CLI 验证必须显式提供主机；VM 专项使用 `ZEROWORK_VM_HOST` 与密码，涉及固定信任校验时还需调用者提供 `ZEROWORK_SFTP_FINGERPRINT`，不得放宽指纹检查。

AI gateway 专项默认跳过；明确开启后必须同时提供 `ZEROWORK_AI_GATEWAY_KEY`、`ZEROWORK_AI_GATEWAY_MODEL`、`ZEROWORK_AI_GATEWAY_CHAT_ENDPOINT` 与 `ZEROWORK_AI_GATEWAY_MODELS_ENDPOINT`。这些只供独立测试进程使用，不是正式 App 配置入口。`v02_grok_gateway.py` 从仓库外 mode-600 配置加载单个 Grok 模型，不使用隐式网关或模型回退。

截图、节点树、运行日志和私有配置保存在仓库外的临时目录，验收后清理，不提交。当前 V3 原型结论与 App 尚未完整同步的边界见。

## 保留的旧认证组件与端口转发回归

旧 `auth_challenge_view` 当前没有生产调用入口。使用 `zig build auth-challenge-preview -Dtest-mode=true` 构建隔离原生验收窗口，再运行 `node e2e/legacy_auth_native.ts /tmp/legacy-auth-new-run dark`（另测 `light`）。窗口复用真实 View 和 InteractiveBridge，覆盖五种认证、标准／最小尺寸、输入遮罩、提交／取消、首次密钥三个决定，以及变更密钥无需输入确认词、点击一次确认即可替换；不建立 SSH、不写信任记录或钥匙串。图标与三主题重着色由 `zig build test-ui -Dui-test-filter='auth challenge'` 验证。

生产转发完整回归使用 `node e2e/forward_controls_native.ts /tmp/forward-new-run dark`（另测 `light`）。只点击一次主机入口；同一 SSH transport 应包含一个 PTY channel 和一个只读系统识别 channel。对端仅将与生产 `remote_os.command` 完全相同的探测记为 `os_probe` 并拒绝执行，其他 exec 仍导致验收失败。三种转发均需完成 8192 字节精确往返、停止后拒绝连接；收尾保留原始 peer trace，再检查唯一 transport、通道数和流量，不能靠删除失败断言通过。


历史PATCH局部回归：`node e2e/patch_history_native.ts zig-out/bin/zerowork /tmp/zerowork-history-review`。先构建最新test-mode二进制；runner只在独立临时数据目录写种子cast/索引，通过主机菜单打开归档，核对Esc、搜索后Esc、1440×900及860×480卡片与内容，保存真实Metal截图。它不连接SSH，也不代表真实远端resize、正常Quit或完整新PATCH已验收。

## 2026-11-04 AI 会话效率验证

契约和实际结果见 [AI_SESSION_EFFICIENCY.md](../docs/DESIGN/AI_SESSION_EFFICIENCY.md)。定向核心回归：`zig build test -Dtest-filter=efficiency -j2`、`zig build test -Dtest-filter='image offload' -j2`、`zig build test-bmc -j2`。Local 原生验收 `ai_execution_lifecycle_native.ts` 使用 interactive readiness、同调用短等待及 terminal wait；分别核对模型精简结果、test-mode 原始 host_result 与落盘 journal/recording，避免用模型文本替代原生执行证据。SSH 使用 `ssh_shell_execution_loopback.py` 的 nominal/nested 模式；KVM 渲染使用 `bmc_kvm_video_frames_native.ts`。实机连接与真实模型渠道另行记录，不以这些隔离 fixture 冒充。

普通受控输入可用 `ZW_AI_TEST_INPUT_ONLY=1` 运行 `ai_execution_input_native.ts`，同时提供 `ZW_AI_TEST_PREFIX` 和与该构建一致的 `ZW_AI_TEST_EXPECTED_SHA256`。该模式核对真实两段文本、单独 Enter、同 key 不重写、模型 consumed 回执与原始 host/journal 证据，正常退出；不打开独立安全输入收集器，也不宣称完成默认三阶段的全部验收。默认完整模式继续保留三个阶段及真实 CUA 安全输入要求。


会话组控件集成验证：先构建 `zig build -Dtest-mode=true -j2`，再运行 `node e2e/session_group_controls_native.ts --binary /absolute/path/to/zerowork --expected-sha <该二进制的SHA256> --out /absolute/empty/evidence`。Runner 使用独立配置、三个真实 Local PTY 和自建回收的 loopback 端口，验证候选滚动、排序／取消、连续拖动建组／入组、独立广播的真实 PID 输入分发、当前成员取消、批量开关、小窗口及选主机新建后保留组。`--pointer-handoff 1` 另建独立原生 App，分别在排序和组右键阶段写入 handoff.json；执行所列 CUA 动作后才写对应 done 标记。未实际执行不能写标记冒充通过。截图人工查看与报告断言分别记录，真实 SSH 重连和 IME 不由此 Runner 证明。


分层与保留面板回归：`zig build -Dtest-mode=true -j2 --prefix /tmp/zw-layer-build` 后运行 `node e2e/layer_regressions_native.ts /tmp/zw-layer-build/bin/zerowork /tmp/zw-layer-regressions`。通过生产设置在 AI 首次打开前、收起后切换三主题，核对原节点、未发送草稿、反复重开及860×480；使用合成背景和独立Local PTY，不发送模型或SSH请求。脚本调用 `layer_regression_pixels.py`（与现有像素回归一样依赖 Pillow），拒绝空白浮层变为整块实色，检查重复重开没有累计加实，以及深色主题草稿确实绘制浅色文字。对应生产组件alpha和内部菜单归属断言：`zig build test-ui -Dui-test-filter=material -j2`。截图仍需人工查看。

KVM 视频及 HUD 分层：`zig build bmc-kvm-preview -Dtest-mode=true -j2 --prefix /tmp/zw-kvm-material-build` 后运行 `node e2e/bmc_material_layers_native.ts /tmp/zw-kvm-material-build/bin/bmc-kvm-preview /tmp/zw-kvm-material-evidence`。生产 View 挂载全局材质策略，覆盖同窗三主题、标准／最小尺寸、透明度端点、FPS、输入提示、五类菜单及嵌套下拉框、说明气泡、启动顺序、日志、断开确认、连接／等待／失败 HUD；Python Pillow 检查真实 Metal 视频像素、HUD 混色以及进度卡片底色和文字对比度。独立原始 typed services 和本地 RGBA 不访问设备；电源及启动写入计数必须为零。对应组件回归为 `BMC material`、`BMC view`、`BMC Select`、`BMC FPS HUD` 的 test-bmc 过滤器。连续视频呈现继续使用 `bmc_kvm_video_frames_native.ts`。

开机命令回显回归：先运行 `zig build ssh-shell-execution-acceptance -j2 -Doptimize=ReleaseFast`，再用已安装 Paramiko 的 Python 执行 `e2e/ssh_startup_commands.py --runner zig-out/bin/ssh-shell-execution-runner --output /tmp/zerowork-startup-check`。测试使用隔离的本地 SSH 和真实 Bash/Zsh PTY，检查延迟提示符下逐条执行与单次回显、提示符超时，以及交互式命令后的人工输入恢复；不连接已保存主机。

v0.4 首个基础增量（Worker 回收）：先执行 `zig build -Dtest-mode=true -j2 --prefix /tmp/zw-v04-build`，再运行 `ZW_AI_TEST_PREFIX=/tmp/zw-v04-build node e2e/ai_worker_release_native.ts /tmp/zw-v04-worker-native`。Runner 启动隔离的生产 App、真实 Local PTY 和 loopback Provider，核对宿主查询的真实工具结果、结束并解绑后历史／草稿保留、恢复不请求模型、明确再次发送后重建执行、流式响应中取消并解绑、860×480 和应用级正常 Quit。报告记录二进制 SHA-256、请求、journal 及 Metal 截图，截图需实际查看。仅 Provider 输出由 fixture 控制；不连接已保存主机或真实模型，不代表子 Agent／技能／MCP 已验收。对应服务回归为 `./scripts/test_isolated.sh test -Dtest-filter='v0.4 Worker' -j2`，包括清理等待、最终保存失败、释放后解绑提交失败及旧 fence 不影响新 Worker；现有 `AiHost integration` 用例继续覆盖回答恢复与跨窗口归属。

应用更新完整回归：`zig build -Dtest-mode=true -Doptimize=Debug -j2 --prefix /tmp/zw-update-e2e` 后执行 `node e2e/app_update_full_native.ts /tmp/zw-update-e2e /tmp/zw-update-normal`，以及 `node e2e/app_update_full_native.ts /tmp/zw-update-e2e /tmp/zw-update-force force`。仅 HTTP 响应由本地签名包提供；运行真实主程序、下载与签名校验、独立安装程序、替换和自动重启，核对旧进程退出、启动／healthy 回执、新版窗口、版本页、严格代码签名及数据保留。所有应用与数据均隔离，不替换已安装应用。`app_update_deleted_drafts_native.ts` 另外覆盖先报错、关闭、删除全部会话后重新安装的旧错误缓存回归。


v0.4 子记录与恢复基础：`./scripts/test_isolated.sh test -Dtest-filter='v0.4 child' -j2` 覆盖独立身份与主 owner 索引、当前父 fence／精确 generation、独立／继承上下文、创建键冲突与内容哈希、混合 schema 回放、显式家庭删除、分配失败回滚、独立 Worker、Task 范围停止及父级 End、子成员读取投影与空工具目录。构建 test-mode 到 `/tmp/zw-v04-child-build` 后，运行 `ZW_AI_TEST_PREFIX=/tmp/zw-v04-child-build node e2e/ai_child_recovery_native.ts /tmp/zw-v04-child-recovery-native`：隔离日志保存旧父子绑定，真实 App 先回收孩子再回收父级，子记录不进入主列表，显式恢复父对话不调用模型，再次发送沿新 AgentId 使用原 ConversationId；保留原 child identity／创建来源且不自动绑定子 Worker。报告含二进制 SHA-256、原 journal、标准／860×480 Metal 截图和应用级 Quit 结果。该专项不创建模型子任务，不作为任务协作／预算／技能／MCP／子弹窗已完成的证据。


v0.4 子任务协作增量：`./scripts/test_isolated.sh test -Dtest-filter='v0.4' -j2` 覆盖共享请求／工具预算、人工与模型排队时间、全局 4／根 2 模型槽及根间轮转、4 个未收尾孩子、原子首任务提交与分配失败、任务日志 schema 3 和降级拒绝、重启不复活、回执幂等、事件确认无自唤醒、复用 generation、当前 handoff fence、压缩请求统一计费及最终事实提交重试。宿主桥定向回归为 `./scripts/test_isolated.sh test-ui -Dui-test-filter='host' -j2`。

原生协作验收：`zig build -Dtest-mode=true -j2 --prefix /tmp/zw-v04-task-build` 后运行 `ZW_AI_TEST_PREFIX=/tmp/zw-v04-task-build node e2e/ai_task_gateway_native.ts /tmp/zw-v04-task-gateway`；另以新的输出目录追加 `steer` 参数，验证父级等待孩子时用户引导仍进入原 Task／Turn。脚本使用隔离数据、真实 Local PTY 和 loopback Provider，经真实模型工具目录创建仅材料子任务，检查子级不获得委派能力、父级提前回答后保留原 Task 等待并收集真实报告、孩子释放早于父级完成、原根任务收尾后才消费 queue，以及累计请求／工具计数和正常应用 Quit。报告含请求、journal、二进制哈希和原生截图，需实际查看。无远端命令、付费模型或已保存主机操作；不作为子弹窗、人工审批交互入口、异步交接、技能或 MCP 已完成的证据。


本地技能与 MCP 专项：`zig build -Dtest-mode=true --prefix /tmp/zw-v04-extensions-build -j2` 后运行 `ZW_AI_TEST_PREFIX=/tmp/zw-v04-extensions-build node e2e/ai_extensions_native.ts /tmp/zw-v04-extensions-native`。使用隔离数据目录、Local PTY、受控 Provider 和真实本地 stdio / HTTP MCP 服务，验证原生导入／查看、两种配置表单、只发现能力的显式连接测试、秘密引用保存、撤销、紧凑窗口、确认模式审批及技能读取到 MCP 材料调用的真实工具链；不执行终端业务命令，正常应用退出。系统文件选择器、真实拖入和第三方远端认证不在自动化覆盖范围。

v0.4 默认策略与活动子任务交接：构建 `zig build -Dtest-mode=true -j2 --prefix /tmp/zw-v04-completion` 后运行 `ZW_AI_TEST_PREFIX=/tmp/zw-v04-completion node e2e/ai_child_defaults_handoff_native.ts /tmp/zw-v04-child-handoff-native`。使用隔离配置、Local PTY 和 loopback Provider；实际搜索并选择子 Agent 默认上下文／复用策略，验证全局保存、撤销和 860×480 窗口；省略 reusable 使用捕获的 prefer_reuse，显式 independent 覆盖继承默认。让子 Provider 真正运行后由父级调用 create_group，核对子请求取消与解绑先于 handoff，父级保留原 Task／root、收取报告后完成，并正常应用级 Quit。产物包含二进制哈希、请求、journal、设置几何和原生截图。该专项只证明设置与交接；子 Agent 列表、可写弹窗和独立审批另见下述子对话专项。

对应定向检查：`./scripts/test_isolated.sh test -Dtest-filter='v0.4' -j2`，`./scripts/test_isolated.sh test -Dtest-filter='settings' -j2`，`./scripts/test_isolated.sh test-ui -Dui-test-filter='lifecycle controller' -j2` 和 `./scripts/test_isolated.sh test-ui -Dui-test-filter='tab grouping native drop' -j2`。异常复用覆盖当前账本与恢复事实、只读新任务不改写旧 unknown、伪造动态写调用被宿主拦截、目标不相交与 reconnect generation 不能绕过重叠约束；拖放检查等待期间不建半成品组、原目标成员版本变化时不发布。


v0.4 子智能体对话与设置气泡：`zig build -Dtest-mode=true --prefix /tmp/zw-child-ui-build -j2` 后运行 `ZW_AI_TEST_PREFIX=/tmp/zw-child-ui-build node e2e/ai_child_dialog_native.ts /tmp/zw-child-dialog-new-run`。使用隔离数据、真实 Local PTY 与 loopback Provider，验证子提问／审批只消费原子票据、命令仅执行一次、父子草稿和真实拖入图片隔离、非复用子对话的显式用户续行、子模型独立与父权限上限、后台 queue／steer、主标题栏打开列表及标题／LOGO／状态列对齐、主子共用 600×456 默认尺寸、设置气泡宽 320 且自然撑高、名称同行与任务记录折叠／展开／数量不截断、时间线几何不变、最大化恢复、收起重开保留草稿、860×480、历史子详情只读与显式恢复父对话不发模型请求，最后正常 Quit。报告记录二进制 SHA-256、请求、journal 和 Metal 截图，必须实际查看。核心与 UI 定向使用 `v0.4`、`AI composer`、`v0.4 child list`、`conversation UI` 过滤器。受控回答不替代真实模型／外部 MCP／远端业务验收。

标准 MCP 与飞书 CLI 只读验收：先构建启用 harness 的应用，运行
`ZW_AI_TEST_PREFIX=/tmp/zw-standard-mcp-build node e2e/ai_extensions_native.ts /tmp/zw-standard-mcp-native`。
真实飞书验证使用 `e2e/lark_cli_mcp_native.ts`，要求现有 `lark-cli` 用户登录，
`ZW_LARK_TEST_DOC_FILE` 指向保存现有已授权文档 URL 的本地文件。
适配器只开放身份、文档目录及搜索读取，复用 CLI 凭据、不导出 token，
只在隔离数据目录配置 MCP。若账号缺少搜索权限，验收确认错误被正确返回，
不会发起额外授权。报告只记录状态与调用名，不保存文档正文或凭据。


## 官方 MCP 参考服务

先构建 `zig build -Dtest-mode=true --prefix /tmp/zw-standard-mcp-build -j2`，再安装固定的官方服务依赖并运行：

```sh
npm ci --prefix e2e/fixtures/mcp-reference --ignore-scripts
ZW_MCP_REFERENCE="$PWD/e2e/fixtures/mcp-reference" node e2e/mcp_reference_native.ts /tmp/zerowork-mcp-reference-evidence
```

Runner 使用未修改的官方 Everything 2.2.1 和 SDK 1.32.2 两个 HTTP 示例，独立启动 Node 服务、原生应用、data/RPC 目录与本地 Provider 响应服务；不接触正式应用配置或飞书数据。验证 stdio／Streamable HTTP、resources／templates／prompts／completion、roots、采样前后人工审阅、表单默认值和拒绝、多轮 opaque requestState、2026 URL 输入、Mcp-Param 请求头及独立 POST SSE 订阅更新、OAuth 401 提示／浏览器 PKCE 登录／受保护工具、URL 导航审阅及 -32042 不自动重放。浏览器会打开 localhost 授权及演示页面；URL accept 表示同意访问，不代表网页事务完成。示例页面不需要真实密钥或付款。

输出包含报告、原生截图和日志。报告记录实际服务版本与执行步骤，最后必须正常退出原生应用并结束自建服务。生产应用不依赖这些 Node 包。`ZW_MCP_START_PHASE=1` 或 `2` 仅用于定向调试后半段；完整验收不设置此变量。

Everything 的 stdio／HTTP 必须实际协商为 2026-07-28；旧版 SDK 示例继续覆盖 2025-11-25 兼容。`ZW_MCP_UI_ONLY=1 ZW_MCP_THEME=reference-light` 可只运行 V4 服务列表的浅色／860×480 几何与原生操作验收，完整运行同时覆盖深色界面。
