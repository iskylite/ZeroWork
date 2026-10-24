# ZeroWork 原生窗口验证

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

`visible` 会等待节点实际获得可见尺寸；`hidden` 会等待节点消失或不可见，可用于确认页签真实移除。`capture` 等待 300ms 让控件进出动画结束后保存视觉证据；它不替代功能完成断言。

`rect` 可按test_id核对实际全局坐标（x/y/width/height，容差0.5px）。`visible/hidden`检查整条祖先可见链，避免隐藏容器内旧节点误判。

`drag` 支持test_id、to_test_id、edge(before/after)及cancel，cancel会在鼠标松开前发送Esc；`tab_order`通过实际可见坐标核对TabId顺序。`block_config_save`仅操作本次Runner自建data目录，将原config.toml改名保留后创建同名目录，用于触发真实写盘失败，不修改产品保存逻辑或用户默认数据。

页签快捷键专项使用 `node e2e/tab_shortcuts.ts --out /absolute/evidence --fixture-dir /absolute/local-refused-fixture`。Fixture 提供一项已保存的本地拒连连接和短连接超时；Runner 创建十个真实会话页签，核对前九项 Command 序号及逐项切换、无 Command 修饰的下一事件恢复图标、860px 下 overflow 首尾几何与禁用门禁，以及连续 Ctrl+Tab 的完整 MRU 顺序和 Shift 反向。查询只读取页签子树，避免完整终端树超过 Harness 结果上限。

该专项仅用公开 Harness API，后台启动独立 PID/data/RPC。当前 Harness 没有 `key_up`，因此 Command/Control 实际松开、窗口失焦与真实 IME 仍需另外通过 CUA 验证；无修饰的 `key_down` 不能作为实际松开凭据。

`scroll` 通过目标节点中心发送真实Harness滚轮事件（`test_id`、`dy`）；`focused` 核对当前实际焦点的 `test_id`，用于阅读位置与浮层回焦验收。按键名沿Harness公开接口使用小写（例如 `backspace`、`return`），不能把未知名称返回ok当成按键已生效。

`hover` 按 `test_id` 通过公开Harness鼠标移动并等待tooltip延迟，可验证不可用原因和完整标题；不能把它当成原生系统鼠标/输入法验收。

## 私有实机输入与证据

仓库不保留实际服务器配置、主机指纹、Provider 私有端点或密钥；一次性用户网络验收脚本已清理。保留的 loopback/fixture 及本地回归只使用受控资源。远端 CLI 验证必须显式提供主机；VM 专项使用 `ZEROWORK_VM_HOST` 与密码，涉及固定信任校验时还需调用者提供 `ZEROWORK_SFTP_FINGERPRINT`，不得放宽指纹检查。

AI gateway 专项默认跳过；明确开启后必须同时提供 `ZEROWORK_AI_GATEWAY_KEY`、`ZEROWORK_AI_GATEWAY_MODEL`、`ZEROWORK_AI_GATEWAY_CHAT_ENDPOINT` 与 `ZEROWORK_AI_GATEWAY_MODELS_ENDPOINT`。这些只供独立测试进程使用，不是正式 App 配置入口。`v021_grok_gateway.py` 从仓库外 mode-600 配置加载单个 Grok 模型，不使用隐式网关或模型回退。

截图、节点树、运行日志和私有配置保存在仓库外的临时目录，验收后清理，不提交。当前 V3 原型结论与 App 尚未完整同步的边界见[版本状态](../docs/DEVELOPMENT/V0.2.1_STATUS.md)。
