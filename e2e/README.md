# ZeroWork 原生窗口验证

AI 答复恢复专项：`zig build ai-recovery-preview -Dtest-mode=true -j2` 后运行 `node e2e/ai_answer_recovery_native.ts /tmp/zerowork-answer-recovery`。隔离窗口复用生产恢复卡片，以合成快照检查未知结果、冷却、上下文失败的可见说明、按钮禁用、详情及 600/360 逻辑宽度。命令不重放、未知回执保留、异常工具调用拒绝和归属／预算检查由 `zig build test -Dtest-filter='answer retry' -j2` 验证；卡片预览不代表真实 SSH 已核查。

原调用只读核查：同一 `ai-recovery-preview` 构建后运行 `node e2e/ai_readonly_verification_native.ts /tmp/zw-readonly-verification`，检查原目标、追加证据、旧记录缺少定位信息、原连接失效及 600/360 布局，核查后新计划仍禁用。`zig build test -Dtest-filter='readonly verification' -j2` 和 `zig build test-ui -Dui-test-filter='readonly verification' -j2` 覆盖调用/参数与generation绑定、原SSH快照、零取消/关闭/重放、终端观察不回退到有副作用的snapshot、证据复制及journal重启。`docs/UI_V3/ai/readonly-verification.html` 是可编辑参考；预览与受控回执不代替真实服务器业务后果核验。


使用仓库实际依赖的 Zenit Harness 和本机 Node 26，无需安装服务或 npm 依赖。

```sh
zig build -Dtest-mode=true -De2e-port=19818 -j2
node e2e/workspace.ts --out /absolute/path/to/evidence
```

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

传输入口、轮播和未读角标专项：先执行 `zig build -Dtest-mode=true -j2`，再运行 `ZW_TEST_PYTHON=/absolute/python-with-paramiko node e2e/transfer_entrypoints_native.ts /absolute/bin/zerowork /absolute/fresh-output --live-transfers`。同一命令增加 `--foreground` 验证前台底栏直接展示后清除角标，会激活独立临时数据窗口；默认后台模式验证未查看角标 2 → 打开列表清零 → 新任务角标 1 → 再次查看清零。两种模式均使用自建 loopback SFTP、实际上传和接收端 SHA-256，核对 3 秒轮播、进度／速度／数量、悬停不弹窗、两个入口共用右上角浮窗、860×480、任务完成后不恢复角标和正常 Quit。Runner 设置 `ZENIT_E2E_REAL_ACTIVATION=1`，避免 Harness 默认的活动外观模拟掩盖真实前后台状态。SFTP 栈溢出定向回归为 `zig build test-ui -Dui-test-filter='SFTP progress' -j2`，包括 2 MB 栈上的连续刷新与快照独立性检查。

通用结构回归：`zig build test-ui -Dui-test-filter='UI constraints' -j2`。其他模块专项及未通过边界见，不能将单个runner通过称为所有操作全绿。

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

KVM 视频及 HUD 分层：`zig build bmc-kvm-preview -Dtest-mode=true -j2 --prefix /tmp/zw-kvm-material-build` 后运行 `node e2e/bmc_material_layers_native.ts /tmp/zw-kvm-material-build/bin/bmc-kvm-preview /tmp/zw-kvm-material-evidence`。生产 View 挂载全局材质策略，覆盖同窗三主题、标准／最小尺寸、透明度端点、FPS、输入提示、五类菜单及嵌套下拉框、说明气泡、启动顺序、日志、断开确认、连接／等待／失败 HUD；Python Pillow 检查真实 Metal 视频像素、HUD 混色及进度玻璃采样。独立原始 typed services 和本地 RGBA 不访问设备；电源及启动写入计数必须为零。对应组件回归为 `BMC material`、`BMC view`、`BMC Select`、`BMC FPS HUD` 的 test-bmc 过滤器。连续视频呈现继续使用 `bmc_kvm_video_frames_native.ts`，场景与限制见 [分层说明](../docs/UI_V3/LAYER_MATERIALS.md#kvm-视频与-hud-的原生分层验收2026-11-05)。

开机命令回显回归：先运行 `zig build ssh-shell-execution-acceptance -j2 -Doptimize=ReleaseFast`，再用已安装 Paramiko 的 Python 执行 `e2e/ssh_startup_commands.py --runner zig-out/bin/ssh-shell-execution-runner --output /tmp/zerowork-startup-check`。测试使用隔离的本地 SSH 和真实 Bash/Zsh PTY，检查延迟提示符下逐条执行与单次回显、提示符超时，以及交互式命令后的人工输入恢复；不连接已保存主机。
