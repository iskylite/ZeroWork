# 连接与资产管理 · V3 可交互设计

> 当前评审： [2026-10-26 修订说明](../REVIEW_20261026.md) · [效果图总览](../review-20261026.html)。本轮替代下文与其冲突的侧栏、会话、气泡、连接页与 KVM 展示规则；待用户确认后再落地 APP UI。
[新建连接](index.html) · [连接管理](index.html?open=none) · [KVM 配置](index.html?protocol=kvm)

这是依据现有原生 APP、V3 视觉规范及 Figma 连接/路径契约补建的可编辑 HTML/CSS/JS 原稿。历史 `artifacts/connection-experience-proposal/connection-modal-v3.html` 文件尚未找回；本稿不冒充历史文件恢复。使用本目录脚本与样式，无构建、CDN或网络请求。首页入口打开的是真正表单，可输入、切换、校验、测试、保存和进入认证状态。

## 功能与入口

| 功能 | 可操作路径与结果 | 对应原生组件 |
| --- | --- | --- |
| 资产列表 | 协议/分组/关键词筛选、无匹配清除、置顶排序 | Sidebar / Input / Select / ScrollArea |
| 主机动作 | 连接、编辑、复制配置、删除确认、更多菜单；更多含新页签/新窗口、历史、分组移动、置顶 | Menu / Modal / Button |
| 资产分组 | 新建、编辑、删除；删除只移动主机至未分组，不删除主机 | Modal / Input / Select |
| 即兴直连 | `user@host[:port]` / `ssh user@[IPv6]:port`；非法端口或缺用户报错；临时连接不入资产 | Input / Popover / NotificationHost |
| 三步向导 | 1 连接与认证＋高级折叠；2 有序路径；3 核对摘要＋测试。固定头脚，步骤往返保留草稿 | Modal / Tabs / Input / Select / ScrollArea |
| 协议 | SSH、SFTP、BMC iKVM、FTP/FTPS、VNC、RDP；协议默认端口及私有配置 | 插件 ConnectionEditor 槽位 |
| SSH 认证 | 密码、私钥路径/口令、SSH Agent；strict_host_key 布尔策略新建/编辑同处；启动命令仅 SSH | Select / Input |
| KVM 配置 | BMC HTTPS 地址/端口、独立用户名密码、显示与只读、SSH 路由 | Input / Select / Switch |
| FTP / RDP 配置 | 显式/隐式 TLS / FTP、主动/被动模式；RDP 域；图形协议比例与只读 | Select / Input / Switch |
| 有序路径 | 添加/删除/上移/下移、防重复校验、完整路径预览，直连隐藏仍保留路径草稿 | Select / Button / List |
| 测试与草稿 | 测试绑定当前草稿；字段变化或取消使旧测试结果失效。保存失败/版本冲突演示保留草稿；编辑深拷贝 route，不改原资产 | controller state / NotificationHost |
| 保存语义 | 仅保存不连接；保存并连接先保存再启动一个独立会话；非秘密配置留在当前页面内存 | Host asset save / SessionHost |
| 连接进度 | 原路径每一跳状态→认证→成功；取消保留配置；失败重新认证或按完整原路径重试 | Progress / Modal / ConnectionLogs |
| 信任与认证 | 新主机密钥、密钥变更阻止、BMC TLS 证书、密码/私钥口令/Keyboard-interactive/Agent 后补密码 | challenge Modal / Input |
| 导入/导出 | JSON 格式校验，导出排除密码，仅页面内存；用户点击才下载非秘密演示文件 | Modal / Input / system file picker in native |
| 边界与主题 | 1440×900、860×480切换，侧栏折叠48px、模态受控滚动、窗口内Tooltip；Dark/Light/Sauber | tokens / Tooltip / Modal |

## 引用与视觉合同

- 已落地参考：`src/ui/quick_connect.zig`、`quick_connect_view.zig`、`connection_host.zig`、`plugin_editor_host.zig`，公共资产与配置宿主。
- KVM：`docs/DESIGN/V0.3_BMC_IKVM.md` §3（配置/独立连接/有序路径/测试边界）。Figma 证据由根任务统一保存于 `../verification/figma-reference.json`；本任务另实读启动节点 `1066:217241` 的字段和样式。
- V3 tokens 最后加载 ../theme-tokens.css，遵循 DESIGN_STANDARDS §2.2：bg #060608、surface-1 #131316、surface-2 #1b1b1f、well #0c0c0f、overlay #18181c。字体使用本地 Inter / JetBrains Mono 和系统中文字体；17px/1.7线性SVG。
- 默认 App 1440×900，外圆角14，壳外边距8、区域间距6，展开侧栏224/折叠48；连接模态760×710（小窗最大432高，内部滚动），头脚固定。尺寸选择是评审工具，不属于产品功能。

## 与工作区共用向导

`?embed=1&protocol=ssh&theme=dark` 只显示透明背景内的模态。工作区用共享同源 HTML 文档宿主（`shared/document-host.js`，`object`）嵌入，保存/连接/取消通过：

```js
parent.postMessage({
  type: 'zerowork-connection',
  action: 'saved' | 'connect' | 'cancel',
  connection: { name, protocol, address, user, port, route: [{ id, name, address, port, user }] }
}, location.origin)
```

`connect` 由工作区创建会话，嵌入页不再创建第二次连接。取消或 Escape 返回原工作区。父页必须校验 origin 和消息类型。这个桥只服务 HTML 原型，不是原生插件接口。

## 验证与边界

已在 Codex 浏览器实际点击：必填校验；三步切换；名称/地址草稿保留；两跳添加、调序、核对原路径；测试；保存失败保留字段；保存并连接只新增一个资产；失败进入认证/关闭。相关状态通过[连接 HTML 原型](index.html)中的表单、测试和失败流程查看。后续覆盖审计和嵌入桥验收由根任务汇总。

所有连接、认证、TLS信任、主机密钥、文件和测试均为本地夹具。没有读取系统凭据或磁盘配置，没有真实连接、HTML 不访问原生钥匙串；密码保存交互以当前文档内存凭据夹具模拟，刷新后清除，不写入localStorage、URL或配置导出。新窗口用独立浏览器页模拟。真实输入法、文件选择、系统信任库及真实连接取消/释放需原生落地验收。所有新稿待用户确认；本任务未修改原生代码，未提交 Git。

### 最终独立审计补充

资产更多菜单、移动分组、新建分组空态及逐跳失败由独立审计实际点击。失败阶段禁用目标继续认证/信任，重试原路径返回connecting，并保留route原顺序。分组编辑预填原名，保存改名后筛选仍指向新分组。最终资源版本为 `20261025-audit-12`。最小窗实测App860×480、Modal760×432，边界内受控滚动。

本轮逐项操作、尺寸与原生映射以 [独立审计](../verification/connection-protocols-audit.md) 为准。新增从已有主机复制、私钥文件选择夹具；高级项与当前原生编辑器一致，超时15秒/KeepAlive30秒为全局只读默认，UTF-8只读，压缩可选，启动命令每行一条。产品 Select 使用 APP 内列表，评审故障开关移到 APP 外。

## 当前设计与可复用功能组件

当前入口仅SSH、SFTP、KVM。FTP/VNC/RDP须显式`future=1`，属未来设计，不进入当前整机预览。

组件故事复用本页唯一编辑器与状态控制器：`?feature=connection-review`（核对测试）、`connection-route`（路径编辑）、`connection-auth`（认证挑战）。可附加`protocol=SSH|SFTP|KVM`。`editName`匹配已有主机；未匹配时`hostName/address/user/port/route`预填快照。正常导航仍使用现有打开/保存入口，不以故事夹具替代业务状态。

本轮调整与实际测量见[一致性检查](verification/consistency/README.md)。

## 本轮定点修正（2026-10-25）

冻结依据为拆分组件前已确认的完整连接模块；本轮未重画资产列表、侧栏或壳结构，仅按用户明确问题修正：步骤条移出正文滚动区、路径箭头垂直居中、直连/跳板使用并列选择块、增加保存密码/仅本次使用交互。详见[实际点击记录](verification/round3/README.md)。原生密码持久化契约使用 `config/store.zig` → `credential_store` → 系统钥匙串；HTML内存夹具不能代替原生验收。
